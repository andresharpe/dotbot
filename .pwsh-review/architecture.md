# Architecture

This file documents the high-level shape of the dotbot codebase. Loaded by every reviewer agent so they can check changes against project intent. Keep it accurate.

## Project shape

dotbot is a structured AI-assisted development framework written in PowerShell 7.0+. The repo is organized as a monorepo containing:

- A small public PowerShell module (`dotbot`) that ships via PowerShell Gallery and exposes a single entry point (`Invoke-Dotbot`).
- A larger `core/` framework that gets copied into target projects under `.bot/` during `dotbot init`. It contains an MCP server (stdio, protocol 2024-11-05), a web UI (vanilla JS frontend backed by a pwsh HTTP server), and a runtime layer that supervises Claude/Codex/Gemini CLI invocations as tracked processes.
- Workflow content under `workflows/<name>/` (start-from-jira, start-from-pr, start-from-prompt, start-from-repo) that is also copied into target projects.
- A separate `server/` subtree (.NET project, out of scope for pwsh review beyond its deploy/test scripts).

The code shape is a **multi-module collection of script-modules plus standalone scripts**. Modules do not follow the canonical `Public/`/`Private/` split; they declare exports inline via `Export-ModuleMember`.

## Module map

<!-- TODO: regenerate with /pwsh-review-bootstrap --refresh after structural changes -->

| Module | Path | Public functions | Internal functions | Tests |
| ------ | ---- | ---------------- | ------------------ | ----- |
| dotbot | `dotbot.psm1` | `Invoke-Dotbot` (+ alias `dotbot`) | 0 | indirect via `tests/Test-Structure.ps1` |
| ClaudeCLI | `core/runtime/ClaudeCLI/ClaudeCLI.psm1` | `Invoke-ClaudeStream`, `Invoke-Claude`, `Get-ClaudeModels`, `New-ClaudeSession` | many | `tests/Test-MockClaude.ps1` |
| ProviderCLI | `core/runtime/ProviderCLI/ProviderCLI.psm1` | provider abstraction over Claude/Codex/Gemini | many | `tests/Test-MockClaude.ps1` |
| WorktreeManager | `core/runtime/modules/WorktreeManager.psm1` | `New-TaskWorktree`, `Complete-TaskWorktree`, `Get-TaskWorktreePath`, `Get-TaskWorktreeInfo`, `Remove-OrphanWorktrees`, others | many | indirect (Test-Components, Test-WorkflowIntegration) |
| SettingsLoader | `core/runtime/modules/SettingsLoader.psm1` | `Get-MergedSettings`, `Merge-DeepSettings` | 0 | `tests/Test-Components.ps1` (SettingsLoader Module section) |
| ProcessRegistry | `core/runtime/modules/ProcessRegistry.psm1` | task/process lifecycle | many | `tests/Test-ProcessRegistry.ps1` |
| MergeConflictEscalation | `core/runtime/modules/MergeConflictEscalation.psm1` | `Move-TaskToMergeConflictNeedsInput`, `Invoke-MergeConflictEscalation` | 0 | indirect |
| ManifestCondition | `core/runtime/modules/ManifestCondition.psm1` | `Test-ManifestCondition` | 0 | indirect |
| InstanceId | `core/runtime/modules/InstanceId.psm1` | `Get-OrCreateWorkspaceInstanceId` | 0 | indirect |
| DotBotTheme | `core/runtime/modules/DotBotTheme.psm1` | theme + structured terminal helpers (`Write-Status`, `Write-Banner`, etc.) | many | indirect |
| DotBotLog | `core/runtime/modules/DotBotLog.psm1` | `Initialize-DotBotLog`, `Write-BotLog` | many | indirect |
| ConsoleSequenceSanitizer | `core/runtime/modules/ConsoleSequenceSanitizer.psm1` | `Remove-ConsoleSequences`, `ConvertTo-SanitizedConsoleText`, `Update-ProcessHeartbeatFields` | 0 | indirect |
| MCP core helpers | `core/mcp/core-helpers.psm1`, `core/mcp/dotbot-mcp-helpers.ps1` | shared parsing/protocol helpers | many | indirect |
| MCP modules | `core/mcp/modules/{FrameworkIntegrity,Manifest,NotificationClient,SessionTracking,TaskIndexCache,PathSanitizer,TaskMutation,TaskStore,Extract-CommitInfo}` | per-module exports | many | per-tool tests in `core/mcp/tools/*/test.ps1` |
| MCP tools | `core/mcp/tools/<tool>/script.ps1` | each tool defines `Invoke-<PascalCaseToolName>` (33 tools) | 0 | colocated `test.ps1` (where present) |
| UI modules | `core/ui/modules/{Aether,Control,Decision,Process,Reference,Settings,Product,Task,Git,State}API.psm1`, `FileWatcher`, `InboxWatcher`, `NotificationPoller`, `StateBuilder` | per-module API surface | many | `tests/Test-StudioAPI.ps1` (and others) |
| Platform-Functions | `scripts/Platform-Functions.psm1` | install-time UI helpers and platform detection | many | `tests/Test-Structure.ps1` |
| StudioAPI | `studio-ui/StudioAPI.psm1` | studio API | many | `tests/Test-StudioAPI.ps1` |
| Test-Helpers | `tests/Test-Helpers.psm1` | Pester support | many | n/a |
| Stack: dotnet DevLayout | `stacks/dotnet/hooks/dev/DevLayout.psm1` | dev layout for the dotnet stack | 0 | n/a |

## Dependency direction

Top-down only:

- `dotbot.psm1` (the published module) bootstraps the global install and delegates to `~/dotbot/bin/dotbot.ps1`.
- `core/runtime/launch-process.ps1` is the unified entry for tracked processes (`task-runner`, `planning`, `commit`, `task-creation`). It drives `core/runtime/modules/*` and `core/runtime/{ClaudeCLI,ProviderCLI}`.
- `core/ui/server.ps1` is a standalone HTTP server that imports `core/ui/modules/*` and reads workspace state.
- `core/mcp/dotbot-mcp.ps1` is a standalone MCP server that auto-discovers tools under `core/mcp/tools/`.
- `core/runtime/modules/*` may depend on `core/mcp/modules/*` (e.g. `WorktreeManager` imports `TaskStore`). The reverse is forbidden.
- Workflow content under `workflows/<name>/` is leaf material: it is copied into target projects but is not imported by `core/`.
- Tests under `tests/` may import any module but no production module may import from `tests/`.

Reverse dependencies (e.g. an MCP tool importing a runtime module) are allowed today via direct `Import-Module` paths, but they should be reviewed - the steady-state direction is runtime → mcp.

## Public surface

<!-- TODO: regenerate with /pwsh-review-bootstrap --refresh -->

The functions exported by the published `dotbot` module:

| Function | Module | OutputType | SupportsShouldProcess |
| -------- | ------ | ---------- | --------------------- |
| `Invoke-Dotbot` (alias `dotbot`) | `dotbot.psm1` | (none declared, returns CLI output) | No |

ClaudeCLI is declared as a module manifest with public exports too (it ships under `~/dotbot` after install but is not on the Gallery):

| Function | Module | OutputType | SupportsShouldProcess |
| -------- | ------ | ---------- | --------------------- |
| `Invoke-ClaudeStream` | `ClaudeCLI` | (none declared) | No |
| `Invoke-Claude` | `ClaudeCLI` | (none declared) | No |
| `Get-ClaudeModels` | `ClaudeCLI` | (none declared) | No |
| `New-ClaudeSession` | `ClaudeCLI` | (none declared) | No |

All other modules are internal framework code consumed via direct `Import-Module` from runtime, MCP, and UI entry points. Their function names are not Gallery-stable, but their cross-module callers depend on them.

## Side-effect boundary

- File I/O is everywhere - this is a framework that manages a `.bot/` workspace. There is no pure/IO split today.
- Git invocations are centralized in `core/runtime/modules/WorktreeManager.psm1` (`Invoke-Git`).
- Task state writes go through `core/mcp/modules/TaskStore.psm1` and `TaskMutation.psm1`. Inline reads/writes of task files outside these modules are a smell.
- Settings reads must go through `Get-MergedSettings` (`core/runtime/modules/SettingsLoader.psm1`). Direct file reads of any settings layer are banned (enforced via repo CLAUDE.md, expected to be enforced by the conventions agent).
- Logging goes through `Write-BotLog` (`core/runtime/modules/DotBotLog.psm1`). Diagnostic `Write-Verbose`/`Write-Warning`/`Write-Host` are banned in framework code. Terminal output in `scripts/*.ps1` and `install.ps1` must use the theme helpers in `scripts/Platform-Functions.psm1` (banned-function list is in `CLAUDE.md` and enforced by Layer 1 Pester).
- Native command invocation: `git`, `claude`, `codex`, `gemini`, `npx`, `pwsh`. The dotbot install-remote script bootstraps via `irm | iex`.

## External dependencies

### PowerShell modules

| Module | Min version | Purpose |
| ------ | ----------- | ------- |
| `powershell-yaml` | unpinned | reading workflow/manifest/MCP-tool YAML in CI and at runtime |
| `Pester` | 5+ (assumed) | testing framework for layered tests |
| `PSScriptAnalyzer` | unpinned | linting (project-level `PSScriptAnalyzerSettings.psd1` exists) |
| `InjectionHunter` | 1.0.0 | custom PSScriptAnalyzer rules for injection-vector detection (used by pwsh-review security agent) |

### Native commands assumed on PATH

| Command | Purpose | Platforms |
| ------- | ------- | --------- |
| `git` | worktree, branch, merge, commit, blame | all |
| `pwsh` | self-invocation (never `powershell.exe`) | all |
| `npx` / `node` | Claude CLI install in CI | all |
| `claude` | Claude CLI provider | all (Layer 4 only) |
| `codex` | Codex CLI provider (optional) | all |
| `gemini` | Gemini CLI provider (optional) | all |
| `gitleaks` | privacy scan in `core/hooks/verify/00-privacy-scan.ps1` and the pwsh-review static pass | all |
| `actionlint` | GitHub Actions linting in the pwsh-review static pass | reviewer host only |

## Target platform

- pwsh: 7.0+ declared in `dotbot.psd1` and `ClaudeCLI.psd1`. CI uses 7.4+.
- editions: Core only. Desktop (5.1) is explicitly unsupported - the project ships UTF-8 without BOM, which 5.1 cannot read.
- OS: Windows, Linux, macOS. CI runs Layers 1-3 across all three matrix legs.

Cross-platform discipline is honoured throughout: `Get-CimInstance`, registry calls, and `powershell.exe` are gated by `$IsWindows` checks where they appear (4 files: `ClaudeCLI.psm1`, `WorktreeManager.psm1`, `tests/Test-Structure.ps1`, `tests/Test-GoScript.ps1`).

## Build and test

- Install/update: `pwsh install.ps1` (from repo root).
- Tests: `pwsh tests/Run-Tests.ps1` runs Layers 1-3 (no credentials). `-Layer 1|2|3|4` for a specific layer. Layer 4 needs `ANTHROPIC_API_KEY`.
- CI: `.github/workflows/test.yml` runs Layers 1-3 on Windows, Linux, macOS for every push and PR to `main`. Layer 4 runs on schedule (weekly Mon 06:00 UTC) or `workflow_dispatch` with `run_e2e=true`.

Test pyramid:

| Layer | File | What it tests | Credentials |
|-------|------|---------------|-------------|
| 1 | `tests/Test-Structure.ps1` | dependencies, install, platform functions, output hygiene | none |
| 2 | `tests/Test-Components.ps1` | MCP tools, UI APIs, file structure, SettingsLoader | none |
| 3 | `tests/Test-MockClaude.ps1` | analysis/execution flows with mock Claude CLI | none |
| 4 | `tests/Test-E2E-Claude.ps1` | full E2E with real Claude API | `ANTHROPIC_API_KEY` |

Project-specific Pester files: `Test-ActivityLogHygiene`, `Test-Compilation`, `Test-GoScript`, `Test-MCPHandshake`, `Test-MdRefs`, `Test-NoLegacyVocabulary`, `Test-PathSanitizer`, `Test-PrivacyScan`, `Test-ProcessDispatch`, `Test-ProcessRegistry`, `Test-ServerStartup`, `Test-StartFromPromptClarification`, `Test-StudioAPI`, `Test-TaskActions`, `Test-ToolLocal`, `Test-WorkflowIntegration`, `Test-WorkflowManifest`. Mock binaries: `tests/{mock-claude,mock-codex,mock-gemini}.ps1` plus `claude`, `codex`, `gemini` shims.

Naming for tests is `Test-<Name>.ps1` (verb-prefixed), not the canonical Pester `<Name>.Tests.ps1` convention. This is a deliberate project choice (see Conventions below).

## Conventions specific to this project

The reviewer must respect these deviations from generic pwsh defaults:

- **Test file naming.** Tests are `Test-<Name>.ps1` to mirror the verb-noun pattern of source code. Do not flag this against the standard Pester convention.
- **No `Public/`/`Private/` split.** Modules dot-source their own functions and call `Export-ModuleMember -Function ...` inline at the bottom (or via the manifest). Do not flag the absence of `Public/Private/`.
- **No `[OutputType()]` on most internal functions.** Framework code is largely untyped at the function boundary. Flag missing `[OutputType()]` only for functions on the public surface listed above.
- **No comment-based help on internal helpers.** Required only for the public surface.
- **Logging.** Use `Write-BotLog` for diagnostic output. `Write-Verbose`/`Write-Warning`/`Write-Host` are banned in framework code (`core/`, runtime modules, MCP tools, UI modules).
- **Terminal output in `scripts/*.ps1` and `install.ps1`.** Use the theme helpers (`Write-DotbotBanner`, `Write-DotbotSection`, `Write-DotbotLabel`, `Write-Status`, `Write-Success`, `Write-DotbotWarning`, `Write-DotbotError`, `Write-DotbotCommand`, `Write-BlankLine`, `Write-DotbotInfo`). Raw `Write-Host`/`Write-Verbose`/`Write-Warning` are banned in those files. Exempt files: `scripts/Platform-Functions.psm1` (defines the helpers) and `install-remote.ps1` (standalone `irm | iex`). Layer 1 Pester enforces this list.
- **Settings reads.** Always via `Get-MergedSettings -BotRoot $botRoot`. Inline `Get-Content settings.default.json | ConvertFrom-Json` and inline merge loops are banned. Exemptions: writers to the tracked baseline (`Set-AnalysisConfig` and friends, `scripts/workflow-add.ps1`, `scripts/workflow-remove.ps1`, `scripts/init-project.ps1`), the validator `scripts/doctor.ps1`, and per-project workspace state (`instance_id` in `StateBuilder.psm1`).
- **Module imports.** Use `Import-Module ... -Global` so functions resolve from any handler scope. `-Force` is banned in child modules - it nukes the global instance loaded by the top-level script.
- **UTF-8 without BOM.** Required for cross-platform tooling. PSScriptAnalyzer rule `PSUseBOMForUnicodeEncodedFile` is excluded project-wide for this reason.
- **`Write-Host` is allowed for CLI output.** PSScriptAnalyzer rule `PSAvoidUsingWriteHost` is excluded project-wide. Theme helpers internally use `Write-Host`. Library/framework code must still go through `Write-BotLog` or the theme helpers - the reviewer enforces that via the logging rule, not the analyzer rule.
- **Banned vocabulary.** Issue #100 is renaming defaults→settings, prompts→recipes, adrs→decisions, workflow→task-runner. New code must use the new names. Old names that survive in legacy paths are tracked by `Test-NoLegacyVocabulary.ps1`.
- **Task IDs in commit messages.** Implementation commits include a `[task:XXXXXXXX]` tag.
- **`.bot/` directory.** Gitignored in this repo, version-controlled in target repos. Never edit files in `.bot/` here - edit the source under `core/` or `workflows/<name>/`.
