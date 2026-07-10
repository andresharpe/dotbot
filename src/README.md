# dotbot - Autonomous Development Framework

A project-agnostic framework for autonomous software development across Claude Code, Codex, and Antigravity CLIs. Provides task management, single-session task execution, per-task git worktree isolation, a web dashboard, and a PowerShell MCP server.

## Installation

```bash
cd ~
git clone https://github.com/andresharpe/dotbot dotbot-install
cd dotbot-install
pwsh install.ps1
```

The installer sets up the global `dotbot` CLI. To initialise a project, run `dotbot init`. That creates the minimal `.bot/` project state; framework content, provider folders, and MCP configuration are materialised later inside each workflow execution worktree.

### Post-Install Verification

After starting a workflow, inspect its execution worktree to confirm the generated setup:

```bash
# Agents and skills land in every provider's IDE directory inside the worktree
ls .claude/agents/    # implementer, planner, reviewer, tester
ls .claude/skills/    # status, verify, write-test-plan, write-unit-tests
ls .codex/agents/     # same four agents
ls .agents/skills/    # Antigravity CLI workspace skills

# Workflow execution creates or updates .mcp.json in the worktree root.
# Confirm it includes the dotbot server entry.
cat .mcp.json
cat .agents/mcp_config.json

# Launch the runtime + dashboard from an initialized project
dotbot go
```

## Architecture

```
.bot/
├── workspace/                    # Project task state and decision tree
├── .gitignore                    # Keeps .control local
├── .control/                     # Local workflow/stack/runtime state (gitignored)
├── settings/                     # Default settings, theme, and provider configs
│   └── providers/                # claude.json, codex.json, antigravity.json
├── recipes/
│   ├── agents/                   # Agent personas (implementer, planner, reviewer, tester)
│   ├── skills/                   # Technical guidance (status, verify, write-test-plan, write-unit-tests)
│   ├── prompts/                  # Numbered step-by-step processes (analysis, implementation, etc.)
│   ├── includes/                 # Shared prompt fragments
│   └── research/                 # Research templates
├── systems/
│   ├── mcp/                      # MCP server + tools (PowerShell, stdio transport)
│   ├── runtime/                  # Process launcher, modules, worktree manager, provider CLIs
│   └── ui/                       # Web dashboard (PowerShell server + vanilla JS)
├── hooks/
│   ├── dev/                      # Dev environment scripts
│   ├── scripts/                  # Automation (commit-bot-state, steering)
│   └── verify/                   # Pre-commit checks (privacy scan, git clean, git pushed, md refs)
└── workspace/
    ├── product/                  # Product docs (mission.md, entity-model.md, tech-stack.md)
    ├── decisions/                # Architecture decision records
    └── tasks/                    # Task queue (todo/, analysed/, in-progress/, done/)
```

## How It Works

### Single-Session Task Execution

Every task runs in one provider CLI session driven by `100-single-session-task.md`:

- Does focused discovery (or resumes from a `needs-input` handoff without re-exploring)
- Loads applicable decisions and standards as binding constraints
- Implements changes following existing project patterns
- Runs verification scripts (privacy scan, git clean, build, format)
- Commits with task ID references and marks the task done

If human input blocks progress, the session pauses on `needs-input` and resumes the same task once the question is answered. There is no separate analysis provider session.

### Per-Task Git Worktrees

Each task runs in an isolated git worktree:

```
Task-runner picks up task
  → Creates branch: task/{short-id}-{slug}
  → Creates worktree: ../worktrees/{repo}/task-{short-id}-{slug}/
  → Sets up junctions for shared .bot/ directories
  → Copies essential gitignored files (e.g., .env)

Provider session runs in the worktree
  → Discovers, implements, verifies, and commits to task branch

On completion
  → Rebases task branch onto main
  → Squash-merges to main
  → Cleans up worktree and branch
```

This provides full isolation between tasks — a failed task never leaves dirty state in the main working tree.

### Task Lifecycle

```
todo → analysing → analysed → in-progress → done
         │                                     │
         ├→ needs-input (question/split)        └→ squash-merged to main
         └→ skipped (non-recoverable)
```

### Process Launcher

`Invoke-DotbotProcess.ps1` is the unified entry point for all provider CLI invocations (Claude, Codex, Antigravity). It supports multiple process types:

| Type | Purpose |
|------|---------|
| `task-runner` | Single-session task execution loop |
| `planning` | Roadmap generation |
| `commit` | Git operations |
| `task-creation` | Bulk task creation |

Each process gets a registry entry for tracking and is managed through the web dashboard.

### MCP Server

The PowerShell MCP server (`dotbot-mcp.ps1`) exposes tools via stdio transport:

- **Task tools**: create, create-bulk, list, get-next, get-context, get-stats, answer-question, approve-split, mark-todo, mark-analysing, mark-analysed, mark-in-progress, mark-done, mark-needs-input, mark-skipped
- **Decision tools**: create, get, list, update, mark-accepted, mark-deprecated, mark-superseded
- **Session tools**: initialize, update, get-state, get-stats, increment-completed
- **Plan tools**: create, get, update
- **Dev tools**: start, stop
- **Steering**: heartbeat with whisper channel for operator interrupts

Tools are auto-discovered from `.bot/systems/mcp/tools/{tool-name}/` — each tool is a folder with `metadata.json` (schema) and `script.ps1` (implementation).

## Usage

### Launch the Dashboard

```bash
dotbot go
```

Opens the web UI on a random port in the IANA dynamic range (49152–65535) where you can:
- View and manage tasks
- Start analysis and execution processes
- Monitor running processes
- Kick off product planning

### Product Planning

From the dashboard, use the start-from-prompt workflow to:
1. Define product mission and tech stack
2. Generate task groups from the roadmap
3. Expand groups into individual tasks with acceptance criteria

### Autonomous Execution

Start analysis and execution processes from the dashboard. They run in a loop:

1. **Analysis process** picks up `todo` tasks, analyses them, marks them `analysed`
2. **Execution process** picks up `analysed` tasks, implements them, marks them `done`
3. Completed tasks are squash-merged to main automatically

### Manual Task Management

Use MCP tools directly from your AI CLI:

```
task_create       → Create a new task
task_list         → List tasks by status/category/priority
task_get_next     → Get highest priority ready task
```

## Agents

Four TDD-focused agent personas, installed for Claude and Codex under `.claude/agents/` and `.codex/agents/`. Antigravity receives the workspace skills it supports under `.agents/skills/`.

| Agent | Role |
|-------|------|
| **implementer** | Writes production code to make tests pass |
| **planner** | Creates roadmaps and breaks down work |
| **reviewer** | Reviews code quality and patterns |
| **tester** | Writes failing tests first (TDD) |

## Verification Hooks

Pre-commit and post-task verification scripts in `.bot/hooks/verify/`:

| Script | Purpose |
|--------|---------|
| `00-privacy-scan.ps1` | Detect absolute paths and secrets |
| `01-git-clean.ps1` | Ensure no uncommitted changes |
| `02-git-pushed.ps1` | Check for unpushed commits (skipped for task branches) |
| `03-check-md-refs.ps1` | Validate path references in markdown and data files |
| `04-framework-integrity.ps1` | Verify `.bot/` framework files match the SHA256 manifest |

Additional project-specific hooks (dotnet build, dotnet format) can be added.

## Configuration

- **`.bot/settings/settings.default.json`** — Default framework settings
- **`.bot/settings/theme.default.json`** — Dashboard theme
- **`.bot/settings/providers/{claude,codex,antigravity}.json`** — Per-provider CLI and model configuration
- **`.bot/.control/`** — Runtime state (process registry, worktree map, user overrides), gitignored
- **`.mcp.json`** — Project-root MCP configuration generated inside execution worktrees.
- **`.agents/mcp_config.json`** — Antigravity CLI workspace MCP configuration generated inside execution worktrees.

## TODO

- [ ] Create `.bot/setup.ps1` bootstrap script to install tooling dependencies (gitleaks, etc.) and configure git hooks
- [ ] Move pre-commit hook template to `.bot/hooks/git/pre-commit` so it can be installed by setup script
