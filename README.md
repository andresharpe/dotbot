# dotbot-v3

**Structured, auditable AI-assisted development for teams.**

![Overview](assets/overview.png)

## What is dotbot?

Most AI coding tools give you a result but no record of how you got there -- no trail of decisions for teammates to follow, no way to continue work across sessions, and no framework for managing large projects. This is often called "vibe coding": fast output, zero accountability.

dotbot is different. It wraps AI-assisted coding in a managed, transparent workflow where every step is tracked:

- **Plan first, then execute** -- Product specs become task roadmaps. Each task gets pre-flight analysis before implementation begins. Decisions, trade-offs, and rationale are documented as the work happens.
- **Two-phase execution** -- Tasks go through analysis first, then implementation. The analysis phase resolves ambiguity, identifies files and patterns, and builds a context package. The implementation phase consumes that package and writes code.
- **Per-task git worktree isolation** -- Each task runs in its own git worktree on an isolated branch. Work is squash-merged back to main on completion, keeping history clean and preventing cross-task interference.
- **Full session audit trail** -- Every AI session, question, answer, and code change is recorded in version-controlled JSON files. Your team can review exactly what happened, when, and why.
- **Operator steering** -- Guide the AI mid-session through a heartbeat/whisper system. Send corrections or pivot instructions without interrupting its flow.
- **Zero-dependency tooling** -- The built-in MCP server and web UI are pure PowerShell. No npm, pip, or Docker required -- install and go.
- **Designed for teams** -- The entire `.bot/` directory lives in your repo. Task queues, session histories, plans, and feedback are visible to everyone through git.
- **Fully extensible** -- Hooks, verification scripts, agents, skills, and workflows can all be customised per-project. The MCP server and UI can be mutated inside any project to fit your tech stack and dev workflow. Tech-specific profiles (e.g. `dotnet`) overlay additional tooling on top of the base system.

## Prerequisites

**Required:**
- **PowerShell 7+** -- [Download](https://aka.ms/powershell)
- **Git** -- [Download](https://git-scm.com/downloads)
- **Claude CLI** -- Required for autonomous mode

**Strongly recommended MCP servers:**
- **[Playwright MCP](https://github.com/anthropics/anthropic-quickstarts/tree/main/mcp-playwright)** -- Browser automation for UI testing and verification. Dotbot's autonomous agents use this to validate completed work.
- **[Context7 MCP](https://github.com/upstash/context7)** -- Library documentation lookup. Agents use this to resolve API questions without hallucinating.

> **Windows ZIP download?** If you downloaded this repo as a ZIP instead of cloning, you may need to run this first:
> ```powershell
> Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
> ```

## Quick Start

### 1. Install dotbot globally (one-time)

```powershell
cd ~
git clone https://github.com/andresharpe/dotbot-v3 dotbot-install
cd dotbot-install
pwsh install.ps1
```

After installation, **restart your terminal** so the `dotbot` command is available.

### 2. Add dotbot to your project

```powershell
cd your-project
dotbot init
```

This creates a `.bot/` directory with:
- MCP server for task management
- Web UI for monitoring (go.ps1 auto-selects the first available port starting at 8686)
- Autonomous loop for Claude CLI
- Agents, skills, and workflows

### 3. Configure MCP Server

Add to your Claude/Warp MCP settings:

```json
{
  "mcpServers": {
    "dotbot": {
      "command": "pwsh",
      "args": ["-NoProfile", "-File", ".bot/systems/mcp/dotbot-mcp.ps1"]
    }
  }
}
```

### 4. Start the UI

```powershell
.bot\go.ps1
```

Opens the web dashboard at the first available `http://localhost:<port>` starting from `8686`

## Screenshots

| Overview | Product | Workflow | Settings |
|----------|---------|----------|----------|
| ![Overview](assets/overview.png) | ![Product](assets/product.png) | ![Workflow](assets/workflow.png) | ![Settings](assets/settings.png) |

## Commands

```powershell
dotbot help          # Show all commands
dotbot status        # Check installation status
dotbot init          # Add dotbot to current project
dotbot init -Force   # Reinitialize (overwrites existing)
```

### Update Installation

```powershell
cd ~/dotbot-install
git pull
pwsh install.ps1
```

## Architecture

```
.bot/
├── systems/          # Core systems
│   ├── mcp/          # MCP server (task/session tools)
│   ├── ui/           # Web UI server
│   └── runtime/      # Autonomous loop + worktree manager
├── prompts/          # AI prompts
│   ├── agents/       # Specialized AI personas
│   ├── skills/       # Reusable capabilities
│   └── workflows/    # Step-by-step processes (analysis + execution)
├── workspace/        # Runtime state
│   ├── tasks/        # Task queue (todo → analysing → in-progress → done)
│   ├── sessions/     # Session tracking
│   └── product/      # Product documentation
├── hooks/            # Project-specific scripts
├── init.ps1          # Claude Code integration setup
└── go.ps1            # Launch UI server
```

## MCP Tools

The dotbot MCP server provides:

**Task Management**: `task_create`, `task_get_next`, `task_mark_done`, `task_list`, `task_get_stats`

**Session Management**: `session_initialize`, `session_get_state`, `session_get_stats`

**Development**: `dev_start`, `dev_stop`

See `.bot/README.md` for full documentation.

## Troubleshooting

**`dotbot` command not found after install** — Restart your terminal. The installer adds `~/dotbot/bin` to your PATH, but the current session needs a restart to pick it up.

**Script execution blocked on Windows** — Run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` in PowerShell and try again.

**PowerShell version error** — dotbot requires PowerShell 7+. Check your version with `$PSVersionTable.PSVersion` and [upgrade](https://aka.ms/powershell) if needed.

## License

MIT
