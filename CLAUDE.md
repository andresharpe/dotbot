# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dotbot is a structured AI-assisted development framework built entirely in **PowerShell 7+**. It wraps AI coding workflows in managed, auditable processes with two-phase execution (analysis → implementation), per-task git worktree isolation, and a web dashboard for monitoring.

## Commands

**Always use `pwsh` (PowerShell 7), never `powershell` (5.1).** PS 5.1 cannot handle UTF-8 files without BOM.

```bash
# Install/update dotbot globally (from repo root)
pwsh install.ps1

# Run tests (layers 1-3, no Claude credentials needed)
pwsh tests/Run-Tests.ps1

# Run a specific test layer
pwsh tests/Run-Tests.ps1 -Layer 1       # Structure tests
pwsh tests/Run-Tests.ps1 -Layer 2       # Component tests
pwsh tests/Run-Tests.ps1 -Layer 3       # Mock Claude tests
pwsh tests/Run-Tests.ps1 -Layer 4       # E2E (requires ANTHROPIC_API_KEY)

# Initialize dotbot in a project
dotbot init
dotbot init --profile dotnet

# Launch the web UI (default port 8686, auto-selects if busy)
.bot\go.ps1
.bot\go.ps1 -Port 9000   # Use a specific port
```

## Architecture

### Top-level layout

```
src/                      — All source code in this repo
  ├── runtime/             — PowerShell process orchestration, worktrees, provider CLIs
  ├── mcp/                 — PowerShell MCP server with auto-discovered tools
  ├── ui/                  — PowerShell web dashboard server (HTTP + vanilla JS)
  ├── hooks/               — verify/, dev/, scripts/ — framework hooks (PowerShell)
  ├── cli/                 — PowerShell CLI entry points (init-project, install-global, doctor, registry-*, workflow-*, tasks-*)
  ├── go.ps1               — Project-side launcher (copied to .bot/go.ps1)
  ├── init.ps1             — Project-side IDE setup (copied to .bot/init.ps1)
  ├── server-dotnet/       — .NET (ASP.NET Core) question-delivery service for Teams/Email/Jira (sibling product)
  ├── studio-ui/           — React + Vite visual workflow editor (sibling product)
  ├── shared/              — CSS design tokens shared between studio-ui and the Mothership shell
  └── packaging/           — Homebrew + Scoop distribution recipes
content/                  — Framework content copied into target .bot/
  ├── agents/, skills/, prompts/, recipes/
  ├── settings/             — settings.default.json, providers/, theme.default.json
  ├── workspace-template/   — Sample tasks for new projects
  ├── workflows/            — Operational pipelines: start-from-prompt, start-from-jira, start-from-pr, start-from-repo
  └── stacks/               — Tech-specific overlays: dotnet, dotnet-blazor, dotnet-ef (composable via `extends`)
tests/                    — Test pyramid (layers 1-4)
docs/                     — Roadmap, whitepapers, design notes, assets/ (README imagery), specs/ (PRDs)
```

`src/` holds every codebase in this repo; the PowerShell framework (`src/runtime/`, `src/mcp/`, `src/ui/`, `src/hooks/`, `src/cli/`) is the primary product, and `src/server-dotnet/`, `src/studio-ui/`, `src/shared/` are sibling products written in different languages with their own build systems and CI workflows.

`content/` holds everything the PowerShell framework can install into a target project's `.bot/` directory: framework-default content (`agents`, `skills`, `prompts`, `recipes`, `settings`, `workspace-template`) plus the composable selectors (`workflows`, `stacks`). `dotbot init` copies the PowerShell engine subtrees (`src/runtime/`, `src/mcp/`, `src/ui/`, `src/hooks/`, `src/cli/`, `src/go.ps1`, `src/init.ps1`) into `.bot/src/`, the framework defaults into `.bot/content/`, and the user-selected workflows/stacks into `.bot/content/workflows/<name>/` and `.bot/content/stacks/<name>/`. For backwards-compat convenience, init also drops copies of `content/settings/` → `.bot/settings/`, `content/recipes/` → `.bot/recipes/`, and `src/hooks/` → `.bot/hooks/` so existing `Join-Path $BotRoot "settings"`-style callers keep working. The `.bot/` directory in this repo is gitignored — **never edit files in `.bot/`**; always edit the source in `src/` or `content/`. The sibling products under `src/` (server-dotnet, studio-ui, shared) are NOT copied into target projects; only deployable studio-ui assets (`server.ps1`, `StudioAPI.psm1`, `static/`) ship into `~/dotbot/studio-ui/` so `dotbot studio` can find them.

### Three Core Systems (`src/`)

**MCP Server** (`src/mcp/`) — Pure PowerShell MCP server (stdio transport, protocol 2024-11-05). Tools are auto-discovered from `tools/{tool-name}/` subdirectories, each containing `metadata.yaml` + `script.ps1`. 26 tools for task, session, plan, and dev management.

**Web UI** (`src/ui/`) — Pure PowerShell HTTP server with vanilla JS frontend. Dashboard tabs: Overview, Product, Workflow, Processes, Settings, Roadmap. Default port 8686 (auto-selects next available if busy).

**Runtime** (`src/runtime/`) — Manages Claude CLI invocations as tracked processes. `Invoke-DotbotProcess.ps1` is the unified entry point with process types: `task-runner`, `planning`, `commit`, `task-creation`. Includes `WorktreeManager.psm1` for git worktree isolation and `ClaudeCLI.psm1` / `ProviderCLI.psm1` for provider wrappers.

### Recipes & Agents (`content/`)

- **Agents** (`content/agents/`): `implementer/`, `planner/`, `reviewer/`, `tester/` — TDD-focused AI personas
- **Skills** (`content/skills/`): Reusable technical guidance (e.g., `write-unit-tests/`)
- **Framework prompts** (`content/prompts/`): `98-analyse-task.md` (pre-flight analysis) and `99-autonomous-task.md` (execution) are the core two-phase workflow; `90-commit-and-push.md`, `91-new-tasks.md`, `92-steering-protocol.include.md`, `05-retrospective-task.md` round out the framework set.
- **Workflow prompts** live under each `content/workflows/<name>/recipes/prompts/` and stay workflow-scoped.

### Two-Phase Execution

1. **Analysis** (`98-analyse-task.md`): Explores codebase, identifies affected files, builds context package, may propose task splits or request user input. Task moves: `todo → analysing → analysed`.
2. **Implementation** (`99-autonomous-task.md`): Consumes pre-built context, writes code, runs tests, commits with `[task:XXXXXXXX]` tag. Task moves: `analysed → in-progress → done`.

### Git Worktree Isolation

Each task gets its own branch (`task/{short-id}-{slug}`) and worktree (`../worktrees/{repo}/task-{short-id}-{slug}/`). On completion, the task branch is squash-merged to main and the worktree is cleaned up.

### Hooks

- `src/hooks/verify/` — Numbered verification scripts (framework-shared): `00-privacy-scan.ps1` (gitleaks), `01-git-clean.ps1`, `02-git-pushed.ps1`, `03-check-md-refs.ps1`, `04-framework-integrity.ps1`
- `src/hooks/dev/` — `Start-Dev.ps1`, `Stop-Dev.ps1` for dev environment lifecycle
- `src/hooks/scripts/` — `commit-bot-state.ps1`, `steering.ps1`

### Stacks

Stacks add tech-specific skills, hooks, and MCP tools on top of a base workflow. They live in `content/stacks/<name>/` and compose additively via `extends` chains declared in their `manifest.yaml`. Settings deep-merge in the order `default → workflows → stacks`. Install one or more with `dotbot init -Stack dotnet,dotnet-ef`. See `src/cli/init-project.ps1` (`Resolve-StackDir`) for the resolution algorithm including registry-namespaced stacks (`myorg:my-stack`).

## Adding MCP Tools

1. Create folder: `src/mcp/tools/your-tool-name/`
2. Add `metadata.yaml` (snake_case name, JSON Schema), `script.ps1` (PascalCase `Invoke-YourToolName` function), and `test.ps1`
3. Server auto-discovers the tool — no registration needed

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

After every set of changes, run the install script from the project root so the user can test against the latest build, then run level 1-3 tests:

```bash
# 1. Install/update (from dotbot repo root)
pwsh install.ps1

# 2. Run tests (layers 1-3)
pwsh tests/Run-Tests.ps1
```

Always do both steps before considering a dev cycle complete. Do not skip tests.

**Test output efficiency:** Run the test suite once and capture output, then analyze the file — never re-run the full suite just to grep for different patterns.

Always prefix the output filename with the current branch so parallel worktrees and sessions do not overwrite each other's results. Replace forward slashes in branch names so the path stays filesystem-safe:

```powershell
$branch = (git rev-parse --abbrev-ref HEAD) -replace '[\\/]', '-'
pwsh tests/Run-Tests.ps1 2>&1 | Tee-Object -FilePath "/tmp/test-results-$branch.txt"
# Then use Read/Grep on the same file as many times as needed.
```

If the code hasn't changed since the last run, re-read the output file instead of re-running. For targeted iteration, run only the specific test file (e.g., `pwsh tests/Test-Structure.ps1`). Run the full suite once at the end.

## Terminal Output Rules

**Never use raw PowerShell output cmdlets** in `src/cli/*.ps1` or `install.ps1`. All terminal output must go through the theme helpers defined in `src/cli/Platform-Functions.psm1`. This is enforced by a Layer 1 Pester test.

### Banned functions (in CLI scripts)

| Banned | Use instead |
|--------|-------------|
| `Write-Host "text"` | Theme helper (see below) |
| `Write-Host "text" -ForegroundColor X` | Theme helper (see below) |
| `Write-Host ""` | `Write-BlankLine` |
| `Write-Verbose` | `Write-BotLog` (runtime) or `Write-DotbotCommand` (install) |
| `Write-Warning` | `Write-DotbotWarning` |

### Theme helpers (`src/cli/Platform-Functions.psm1`)

| Helper | Purpose | Example output |
|--------|---------|----------------|
| `Write-DotbotBanner -Title "T" -Subtitle "S"` | Major section banner with ═══ lines | Amber banner |
| `Write-DotbotSection -Title "T"` | Section header with ──── separator | Amber header |
| `Write-DotbotLabel -Label "L" -Value "V" [-ValueType Success\|Error\|Warning\|Info]` | Key-value pair | Dim label + colored value |
| `Write-Status "msg"` | Info/progress message | `› msg` (cyan+muted) |
| `Write-Success "msg"` | Success message | `✓ msg` (green) |
| `Write-DotbotWarning "msg"` | Warning message | `⚠ msg` (amber) |
| `Write-DotbotError "msg"` | Error message | `✗ msg` (red) |
| `Write-DotbotCommand "msg"` | Muted/secondary text | Gray text |
| `Write-BlankLine` | Empty line for spacing | Blank line |

### Exempt files

These files are exempt from the output hygiene test because they define the theme or run standalone:
- `src/cli/Platform-Functions.psm1` — defines the theme helpers (uses `Write-Host` internally)
- `install-remote.ps1` — standalone `irm | iex` script with its own inline ANSI palette

## Key Conventions

- Task lifecycle: `todo → analysing → analysed → in-progress → done` (also: `needs-input`, `skipped`)
- Runtime state lives in `.bot/.control/` (gitignored) and `.bot/workspace/` (version-controlled)
- Settings chain (low → high): `settings.default.json` → `~/dotbot/user-settings.json` → `.control/settings.json`. Resolved at runtime via `Get-MergedSettings`; see **Settings Loading Rules**.
- The steering protocol (`steering-heartbeat`) allows operator "whisper" interrupts during autonomous execution

## Settings Loading Rules

Canonical module: `src/runtime/Modules/SettingsLoader/SettingsLoader.psm1`.
Exports: `Get-MergedSettings -BotRoot <path>` and `Merge-DeepSettings`.

Resolution order (low → high): `settings/settings.default.json` → `$HOME/dotbot/user-settings.json` → `.control/settings.json`.

### Readers

All configuration reads resolve through `Get-MergedSettings`. Inline file reads of any layer are banned.

| Banned | Replace with |
|--------|--------------|
| `Get-Content "settings/settings.default.json" \| ConvertFrom-Json` | `(Get-MergedSettings -BotRoot $botRoot).<key>` |
| `Get-Content ".control/settings.json" \| ConvertFrom-Json` | Same. |
| `foreach ($f in @($controlFile, $defaultsFile))` merge loop | Same. |
| Local `function Merge-DeepSettings` | Import from `SettingsLoader.psm1`. |

Import pattern (required in modules that may be loaded independently):

```powershell
if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $botRoot "src/runtime/Modules/SettingsLoader/SettingsLoader.psm1") -DisableNameChecking -Global
}
```

`-Global` is required so functions resolve from any handler scope. `-Force` is banned in child modules — it reloads the module into the caller's private scope and nukes the global instance loaded by the top-level script (`server.ps1`, `Invoke-DotbotProcess.ps1`, MCP server).

### Direct access is correct for

- Writers to the tracked baseline: `Set-AnalysisConfig`, `Set-CostConfig`, `Set-EditorConfig`, `Set-MothershipConfig`, `Set-ActiveProvider`, `src/cli/workflow-add.ps1`, `src/cli/workflow-remove.ps1`, `src/cli/init-project.ps1`.
- Validators checking the tracked file specifically: `src/cli/doctor.ps1`.
- Per-project workspace state that must not inherit from machine-wide layers: `instance_id` in `StateBuilder.psm1`.

### Tests

Unit tests live in `tests/Test-Components.ps1` under `--- SettingsLoader Module ---`. Integration coverage (including no-leak regression) lives in `tests/Test-WorkflowIntegration.ps1` under `GLOBAL USER SETTINGS (runtime)`. Extend those sections when adding merge behavior.

## Workflow Manifest Validation Rules

Canonical helper: `Test-ValidWorkflowDir -Dir <path>` in `src/runtime/Modules/WorkflowManifest/WorkflowManifest.psm1`. Returns `$true` when `<path>/workflow.yaml` exists AND is not whitespace-only.
