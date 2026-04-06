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

The framework source lives in `workflows/` (canonical) and gets copied to `.bot/` on `dotbot init` in target projects. The `.bot/` directory in this repo is gitignored — **never edit files in `.bot/`**, always edit the source in `workflows/default/`. The `default` workflow is the base; stacks like `dotnet` add tech-specific hooks, skills, and tools.

### Three Core Systems (`workflows/default/systems/`)

**MCP Server** (`systems/mcp/`) — Pure PowerShell MCP server (stdio transport, protocol 2024-11-05). Tools are auto-discovered from `tools/{tool-name}/` subdirectories, each containing `metadata.yaml` + `script.ps1`. 26 tools for task, session, plan, and dev management.

**Web UI** (`systems/ui/`) — Pure PowerShell HTTP server with vanilla JS frontend. Dashboard tabs: Overview, Product, Workflow, Processes, Settings, Roadmap. Default port 8686 (auto-selects next available if busy).

**Runtime** (`systems/runtime/`) — Manages Claude CLI invocations as tracked processes. `launch-process.ps1` is the unified entry point with process types: `analysis`, `execution`, `kickstart`, `planning`, `commit`, `task-creation`. Includes `WorktreeManager.psm1` for git worktree isolation and `ClaudeCLI.psm1` for Claude CLI wrapper.

### Recipes & Agents (`workflows/default/recipes/`)

- **Agents**: `implementer/`, `planner/`, `reviewer/`, `tester/` — TDD-focused AI personas
- **Skills**: Reusable technical guidance (e.g., `write-unit-tests/`)
- **Workflows**: Numbered step-by-step processes — `98-analyse-task.md` (pre-flight analysis) and `99-autonomous-task.md` (execution) are the core two-phase workflow

### Two-Phase Execution

1. **Analysis** (`98-analyse-task.md`): Explores codebase, identifies affected files, builds context package, may propose task splits or request user input. Task moves: `todo → analysing → analysed`.
2. **Implementation** (`99-autonomous-task.md`): Consumes pre-built context, writes code, runs tests, commits with `[task:XXXXXXXX]` tag. Task moves: `analysed → in-progress → done`.

### Git Worktree Isolation

Each task gets its own branch (`task/{short-id}-{slug}`) and worktree (`../worktrees/{repo}/task-{short-id}-{slug}/`). On completion, the task branch is squash-merged to main and the worktree is cleaned up.

### Hooks (`workflows/default/hooks/`)

- `dev/` — `Start-Dev.ps1`, `Stop-Dev.ps1` for dev environment lifecycle
- `verify/` — Numbered verification scripts: `00-privacy-scan.ps1` (gitleaks), `01-git-clean.ps1`, `02-git-pushed.ps1`
- `scripts/` — `commit-bot-state.ps1`, `steering.ps1`, `audit-orphaned-files.ps1`

## Adding MCP Tools

1. Create folder: `systems/mcp/tools/your-tool-name/`
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

```bash
pwsh tests/Run-Tests.ps1 2>&1 | tee /tmp/test-results.txt
# Then use Read/Grep on /tmp/test-results.txt as many times as needed
```

If the code hasn't changed since the last run, re-read the output file instead of re-running. For targeted iteration, run only the specific test file (e.g., `pwsh tests/Test-Structure.ps1`). Run the full suite once at the end.

## Terminal Output Rules

**Never use raw PowerShell output cmdlets** in `scripts/*.ps1` or `install.ps1`. All terminal output must go through the theme helpers defined in `scripts/Platform-Functions.psm1`. This is enforced by a Layer 1 Pester test.

### Banned functions (in scripts)

| Banned | Use instead |
|--------|-------------|
| `Write-Host "text"` | Theme helper (see below) |
| `Write-Host "text" -ForegroundColor X` | Theme helper (see below) |
| `Write-Host ""` | `Write-BlankLine` |
| `Write-Verbose` | `Write-BotLog` (runtime) or `Write-DotbotCommand` (install) |
| `Write-Warning` | `Write-DotbotWarning` |

### Theme helpers (`scripts/Platform-Functions.psm1`)

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
- `scripts/Platform-Functions.psm1` — defines the theme helpers (uses `Write-Host` internally)
- `install-remote.ps1` — standalone `irm | iex` script with its own inline ANSI palette

## Key Conventions

- Task lifecycle: `todo → analysing → analysed → in-progress → done` (also: `needs-input`, `skipped`)
- Runtime state lives in `.bot/.control/` (gitignored) and `.bot/workspace/` (version-controlled)
- Settings merge: `.bot/settings/settings.default.json` (checked in) + `.bot/.control/settings.json` (user overrides)
- The steering protocol (`steering-heartbeat`) allows operator "whisper" interrupts during autonomous execution
