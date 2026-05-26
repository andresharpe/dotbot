# AGENTS.md

Guidance for AI agents (Claude Code, Codex, etc.) working in this repository. `CLAUDE.md` is a symlink to this file.

## Project Overview

dotbot is a structured AI-assisted development framework built entirely in **PowerShell 7+**. It wraps AI coding workflows in managed, auditable processes with two-phase execution (analysis → implementation), per-task git worktree isolation, and a web dashboard for monitoring.

## Commands

**Always use `pwsh` (PowerShell 7), never `powershell` (5.1).** PS 5.1 cannot handle UTF-8 files without BOM.

```bash
pwsh bootstrap.ps1                            # One-time: drop PATH shim into ~/.local/bin (Unix) or %LOCALAPPDATA%\Microsoft\WindowsApps (Windows)
$env:DOTBOT_HOME = $PWD                       # Point at this checkout (persist via shell rc / setx)
pwsh tests/Run-Tests.ps1                      # Run layers 1-3
pwsh tests/Run-Tests.ps1 -Layer 4             # E2E (needs ANTHROPIC_API_KEY)
dotbot status                                 # Confirm DOTBOT_HOME + framework git state + active project workflow/provider
dotbot init                                   # Initialise .bot/ in current project (workspace + .gitignore only)
dotbot init -Workflow start-from-jira -Stack dotnet,dotnet-ef
dotbot go                                     # Launch runtime + UI for the current initialized project
dotbot serve                                  # Launch only the low-level runtime
```

## Architecture

```
bin/                       — CLI entry points: dotbot, dotbot.ps1, shim/ (DOTBOT_HOME-routing PATH shim)
src/                       — All source code
  ├── runtime/             — Process orchestration, worktrees, providers (Modules/, Scripts/, Plugins/)
  ├── mcp/                 — PowerShell MCP server, 28 auto-discovered tools
  ├── ui/                  — PowerShell HTTP server + vanilla JS dashboard
  ├── cli/                 — CLI entry points (init-project, doctor, registry-*, workflow-*, tasks-*)
  ├── hooks/               — verify/, dev/, scripts/
  ├── go.ps1, init.ps1     — Project-side launcher / IDE setup (copied to .bot/)
  ├── server-dotnet/       — ASP.NET Core question-delivery service (sibling product)
  ├── studio-ui/           — React + Vite visual workflow editor (sibling product)
  ├── shared/              — CSS design tokens
  └── packaging/           — Homebrew + Scoop recipes
content/                   — Framework content copied into target .bot/
  ├── agents/, skills/, prompts/, recipes/, settings/, workspace-template/
  ├── workflows/           — start-from-prompt, start-from-jira, start-from-pr, start-from-repo
  └── stacks/              — dotnet, dotnet-blazor, dotnet-ef (composable via `extends`)
tests/                     — Test pyramid (layers 1-4)
docs/                      — Roadmap, whitepapers, design notes, specs/
```

The PowerShell framework (`src/runtime/`, `src/mcp/`, `src/ui/`, `src/cli/`, `src/hooks/`) is the primary product. `src/server-dotnet/`, `src/studio-ui/`, `src/shared/` are sibling products with their own build systems and live entirely under DOTBOT_HOME — they are never deployed into a target project's `.bot/`.

`dotbot init` no longer copies the framework into the target project. A fresh `.bot/` contains only `workspace/` (project task / decision tree, tracked) and `.gitignore`. The runtime resolves `src/`, `content/`, `hooks/`, and `content/settings/` from `$env:DOTBOT_HOME` via the layered content resolver. `dotbot init -Workflow X` / `-Stack Y` records the selection in `.bot/.control/settings.json` (per-project, gitignored) and only materialises `.bot/content/workflows/X/` or `.bot/content/stacks/Y/` when the framework source declares an `overrides/` subtree. Registry items (`namespace:name`) are always materialised because their source lives outside DOTBOT_HOME's built-in tier.

**Never edit files in `.bot/`.** Edit the source under `src/` or `content/` and your changes are live the moment `$env:DOTBOT_HOME` points at this checkout.

### Three core systems

- **MCP server** (`src/mcp/`) — stdio transport, protocol 2024-11-05. Tools auto-discovered from `tools/{tool-name}/{metadata.yaml, script.ps1}`.
- **Web UI** (`src/ui/`) — PowerShell HTTP server + vanilla JS. Dashboard tabs: Overview, Product, Workflow, Processes, Settings, Roadmap. Port written to `.bot/.control/ui-port`.
- **Runtime** (`src/runtime/`) — `Scripts/Invoke-DotbotProcess.ps1` is the unified entry point with process types: `task-runner`, `planning`, `commit`, `task-creation`. Module functionality lives under `Modules/Dotbot.*/` (e.g. `Dotbot.Worktree`, `Dotbot.Process`, `Dotbot.Executor`, `ContentResolver`).

### Content resolution (project overrides framework)

`src/runtime/Modules/ContentResolver/` implements project-over-framework lookup. A project can override any content item (agents/skills/prompts/workflows/stacks/recipes) by placing it under `<BotRoot>/content/<Type>/`, or override hook scripts by placing them under `<BotRoot>/hooks/<verify|dev|scripts>/`; the runtime falls back to `<DOTBOT_HOME>` otherwise. Merge is by filename — a project file replaces the framework file of the same name; framework-only files still run. APIs: `Resolve-DotbotContent`, `Get-DotbotContentItems`, `Get-DotbotHookChain`.

### Two-phase execution

1. **Analysis** (`98-analyse-task.md`): explores codebase, builds context package, may propose splits. Task: `todo → analysing → analysed`.
2. **Implementation** (`99-autonomous-task.md`): consumes context, writes code, tests, commits with `[task:XXXXXXXX]` tag. Task: `analysed → in-progress → done`.

### Git worktree isolation

Each task gets its own branch (`task/{short-id}-{slug}`) and worktree (`../worktrees/{repo}/task-{short-id}-{slug}/`). On completion, the branch is squash-merged to main and the worktree cleaned up.

### Hooks

- `src/hooks/verify/` — `00-privacy-scan` (gitleaks), `01-git-clean`, `02-git-pushed`, `03-check-md-refs`, `04-framework-integrity`
- `src/hooks/dev/` — `Start-Dev.ps1`, `Stop-Dev.ps1`
- `src/hooks/scripts/` — `commit-bot-state.ps1`, `steering.ps1`

### Stacks

Stacks add tech-specific skills, hooks, and MCP tools on top of a base workflow. They live in `content/stacks/<name>/` and compose additively via `extends` chains in `manifest.yaml`. Settings deep-merge `default → workflows → stacks`. Install with `dotbot init -Stack dotnet,dotnet-ef`. See `Resolve-StackDir` in `src/cli/init-project.ps1` for resolution (including registry-namespaced stacks like `myorg:my-stack`).

## Adding MCP Tools

1. Create folder: `src/mcp/tools/your-tool-name/`
2. Add `metadata.yaml` (snake_case name, JSON Schema), `script.ps1` (PascalCase `Invoke-YourToolName`), and `test.ps1`
3. Server auto-discovers — no registration needed

Naming: folder=`kebab-case`, YAML name=`snake_case`, function=`Invoke-PascalCase`.

## Test Pyramid

| Layer | File | What it tests | Credentials |
|-------|------|---------------|-------------|
| 1 | `Test-Structure.ps1` | Dependencies, installation, platform functions | None |
| 2 | `Test-Components.ps1` | MCP tools, UI APIs, file structure | None |
| 3 | `Test-MockClaude.ps1` | Analysis/execution flows with mock Claude CLI | None |
| 4 | `Test-E2E-Claude.ps1` | Full end-to-end with real Claude API | `ANTHROPIC_API_KEY` |

CI runs layers 1-3 on push/PR across Windows, macOS, Linux. Layer 4 runs on schedule or manual trigger.

## Dev Cycle

Edits to `src/` and `content/` go live the moment you save — `$env:DOTBOT_HOME` tracks this checkout, no reinstall step. Run layers 1-3 after every set of changes:

```bash
pwsh tests/Run-Tests.ps1
```

Run the test suite **once** and capture output; analyze the file rather than re-running to grep different patterns. Prefix the filename with the current branch so parallel worktrees don't clobber each other:

```powershell
$branch = (git rev-parse --abbrev-ref HEAD) -replace '[\\/]', '-'
pwsh tests/Run-Tests.ps1 2>&1 | Tee-Object -FilePath "/tmp/test-results-$branch.txt"
```

If the code hasn't changed since the last run, re-read the file. For targeted iteration, run a specific test file (e.g. `pwsh tests/Test-Structure.ps1`). Run the full suite once at the end.

## Terminal Output Rules

**Never use raw PowerShell output cmdlets** in `src/cli/*.ps1` or `bootstrap.ps1`. All terminal output must go through theme helpers in `src/cli/Platform-Functions.psm1`. Enforced by a Layer 1 Pester test.

| Banned | Use instead |
|--------|-------------|
| `Write-Host "text"` (with or without `-ForegroundColor`) | Theme helper below |
| `Write-Host ""` | `Write-BlankLine` |
| `Write-Verbose` | `Write-BotLog` (runtime) / `Write-DotbotCommand` (install) |
| `Write-Warning` | `Write-DotbotWarning` |

Theme helpers: `Write-DotbotBanner`, `Write-DotbotSection`, `Write-DotbotLabel`, `Write-Status` (`›` cyan), `Write-Success` (`✓` green), `Write-DotbotWarning` (`⚠` amber), `Write-DotbotError` (`✗` red), `Write-DotbotCommand` (gray), `Write-BlankLine`.

Exempt: `src/cli/Platform-Functions.psm1` (defines helpers).

## Key Conventions

- Task lifecycle: `todo → analysing → analysed → in-progress → done` (also `needs-input`, `skipped`)
- Runtime state: `.bot/.control/` (gitignored, holds workflow/stack selection + instance_id), `.bot/workspace/` (version-controlled)
- Settings chain (low → high): `<DOTBOT_HOME>/content/settings/settings.default.json` → `<BotRoot>/content/settings/settings.default.json` (project override, tracked, optional) → `<user-config>/dotbot/user-settings.json` → `<BotRoot>/.control/settings.json`. See **Settings Loading Rules**.
- Steering protocol (`steering-heartbeat`) allows operator "whisper" interrupts during autonomous execution
- `$env:DOTBOT_HOME` is the env var every layer reads; the `bin/shim/dotbot` PATH shim drops by `pwsh bootstrap.ps1` reads it and execs into `<DOTBOT_HOME>/bin/dotbot.ps1`. The CLI itself trusts its own location; only the shim resolves DOTBOT_HOME.

## Settings Loading Rules

Canonical module: `src/runtime/Modules/Dotbot.Settings/`. Exports `Get-MergedSettings -BotRoot <path>`, `Merge-DeepSettings`, and `Invoke-DotbotUserSettingsMigration`. Resolution order (low → high):

1. `<DOTBOT_HOME>/content/settings/settings.default.json` — framework defaults (always present).
2. `<BotRoot>/content/settings/settings.default.json` — project tracked override (optional, lives in git).
3. `Get-DotbotUserSettingsPath` — `~/.config/dotbot/user-settings.json` (Linux/macOS) or `%APPDATA%\dotbot\user-settings.json` (Windows), machine-local. Decoupled from `DOTBOT_HOME`; a one-time migration on first `Get-MergedSettings` call moves a legacy `<DOTBOT_HOME>/user-settings.json` into the new location.
4. `<BotRoot>/.control/settings.json` — per-project gitignored state (workflow + stacks selection, instance_id, UI writers' overrides).

**All configuration reads resolve through `Get-MergedSettings`.** Inline `Get-Content … | ConvertFrom-Json` on any settings layer, or any local `Merge-DeepSettings`, is banned.

Import pattern for modules loaded independently:

```powershell
if (-not (Get-Module Dotbot.Settings)) {
    Import-Module (Join-Path (Get-DotbotInstallPath) "src/runtime/Modules/Dotbot.Settings/Dotbot.Settings.psd1") -DisableNameChecking -Global
}
```

`-Global` is required so functions resolve from any handler scope. `-Force` is **banned** in child modules — it reloads into the caller's private scope and nukes the global instance loaded by `server.ps1` / `Invoke-DotbotProcess.ps1` / the MCP server.

Direct file access is correct only for: UI writers persisting to `.control/settings.json` via `Save-OverrideSection` (`Set-AnalysisConfig`, `Set-CostConfig`, `Set-EditorConfig`, `Set-MothershipConfig`, `Set-ActiveProvider`); CLI scripts that record workflow/stack selection (`init-project.ps1`, `workflow-add.ps1`, `workflow-remove.ps1`); per-project workspace state that must not inherit machine-wide layers (`instance_id`, lazy-created in `.control/settings.json` by `Invoke-DotbotProcess.ps1` / `StateBuilder.psm1`).

Tests: `tests/Test-Components.ps1` (`--- Dotbot.Settings Module ---` and `Phase 4: dotbot init footprint`) and `tests/Test-WorkflowIntegration.ps1` (`GLOBAL USER SETTINGS (runtime)`).

## Workflow Manifest Validation Rules

Canonical helper: `Test-ValidWorkflowDir -Dir <path>` in `src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1`. Returns `$true` when `<path>/workflow.yaml` exists AND is not whitespace-only.
