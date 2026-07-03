# dotbot v4 — Framework Overview

> dotbot v4 is a PowerShell 7+ AI-assisted development orchestration framework. It coordinates Claude-powered task agents, manages worktrees, routes approvals, and integrates with your existing toolchain — all from a single git checkout.

---

## Contents

1. [What changed in v4](#what-changed-in-v4)
2. [Install](#install)
3. [Core concepts](#core-concepts)
4. [Key commands](#key-commands)
5. [Architecture](#architecture)
6. [Settings chain](#settings-chain)
7. [Workflow & stack model](#workflow--stack-model)
8. [Migration from v3](#migration-from-v3)

---

## What changed in v4

v4 replaces the copy-based installer with a live git checkout model. The framework is no longer copied into your project — it lives in a single location (`DOTBOT_HOME`) and is resolved lazily at runtime.

| | v3 | v4 |
|---|---|---|
| Install | `irm install-remote.ps1 \| iex` copies framework into `~/dotbot` | `git clone` + `pwsh bootstrap.ps1` drops a PATH shim |
| Framework location | Copied into `~/dotbot`, updated via `dotbot update` | One git checkout, `DOTBOT_HOME` points at it |
| Project `.bot/` | Contains copies of `src/`, `content/`, `settings/`, `hooks/` | Contains only `workspace/` and `.gitignore` |
| Settings source | `<BotRoot>/settings/settings.default.json` | `<DOTBOT_HOME>/content/settings/settings.default.json` |
| Entry point | `.bot\go.ps1` / `.bot\init.ps1` | `dotbot runtime-start` |
| PowerShell Gallery | `Install-Module Dotbot` | Retired |

---

## Install

### Requirements

- PowerShell 7.2+ (PowerShell 5.1 is rejected at install time)
- Git

### One-time setup

```powershell
# Clone the framework
git clone https://github.com/andresharpe/dotbot ~/dotbot

# Install the PATH shim and set DOTBOT_HOME
pwsh ~/dotbot/bootstrap.ps1

# Confirm
dotbot status
```

`bootstrap.ps1` drops a shim into:
- **Windows:** `%LOCALAPPDATA%\Microsoft\WindowsApps\dotbot.ps1`
- **macOS / Linux:** `~/.local/bin/dotbot`

It never writes `DOTBOT_HOME` to the machine environment — you set it in your shell profile or project init.

### Package managers

```bash
# Homebrew (macOS / Linux)
brew install andresharpe/dotbot/dotbot

# Scoop (Windows)
scoop bucket add dotbot https://github.com/andresharpe/scoop-dotbot
scoop install dotbot
```

---

## Core concepts

### DOTBOT_HOME

The environment variable that points at your dotbot framework checkout. All runtime modules, content, and settings are resolved from this path. Must be set before any `dotbot` command runs.

```powershell
$env:DOTBOT_HOME = "~/dotbot"   # point at your clone
```

### Project `.bot/`

A minimal directory committed to your project repo. In v4 it contains only:

```
.bot/
  .gitignore
  workspace/          # task files, answers, outputs
  .control/           # runtime state (settings.json, instance_id)
  content/            # project-tier overrides only (created on demand)
```

Framework content (workflows, stacks, MCP tools) is resolved lazily from `DOTBOT_HOME` — never copied into `.bot/`.

### Workflows

A workflow defines the end-to-end process for a class of work (e.g. `start-from-jira`, `start-from-prompt`). Workflows live in `<DOTBOT_HOME>/content/workflows/` and can be extended with `extends:` in `workflow.yaml`.

```yaml
# workflow.yaml
name: my-workflow
extends: start-from-prompt   # inherit from base workflow
```

### Stacks

A stack adds technology-specific content (MCP tools, hooks, settings) layered on top of the framework defaults. Active stacks are declared in `.bot/.control/settings.json` and resolved via the `ContentResolver`.

### Providers

A provider configures the AI model backend (Claude, Codex, Copilot, Gemini). Provider settings live in `<DOTBOT_HOME>/content/settings/providers/`.

---

## Key commands

| Command | What it does |
|---|---|
| `dotbot status` | Shows resolved `DOTBOT_HOME`, framework branch/SHA/dirty flag, version, active workflow, provider, stacks |
| `dotbot status --json` | Same, machine-readable — used by CI scripts and the dashboard banner |
| `dotbot init` | Bootstraps a project `.bot/` directory (sparse — no framework copies) |
| `dotbot init -Workflow start-from-jira` | Init with a specific workflow materialised |
| `dotbot runtime-start` | Starts the task runner and Studio UI for the current project |
| `dotbot workflow add <name>` | Activates a workflow in `.control/settings.json` |
| `dotbot workflow remove <name>` | Deactivates a workflow |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Studio UI  (src/studio-ui/)                        │
│  Browser dashboard · task list · roadmap · approvals│
└───────────────────┬─────────────────────────────────┘
                    │ HTTP
┌───────────────────▼─────────────────────────────────┐
│  Runtime  (src/runtime/)                            │
│  Task runner · worktree manager · MCP preflight     │
│  Inbox watcher · approval router · event emitter    │
└───────────────────┬─────────────────────────────────┘
                    │ PowerShell modules
┌───────────────────▼─────────────────────────────────┐
│  ContentResolver                                    │
│  Framework (DOTBOT_HOME) → Active stacks → Project  │
└───────────────────┬─────────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────────┐
│  Claude (via MCP)                                   │
│  claude.exe · per-task worktree · MCP tool set      │
└─────────────────────────────────────────────────────┘
```

### Content resolution order

The `ContentResolver` folds content in priority order:

1. **Project tier** — `.bot/content/` (project-specific overrides)
2. **Active stacks** — resolved via `extends` chain in `.control/settings.json`
3. **Framework** — `<DOTBOT_HOME>/content/`

The first match wins. This means project overrides beat stack defaults, which beat framework defaults.

---

## Settings chain

Four layers merged in order (last wins):

| Layer | Source | Purpose |
|---|---|---|
| 1 — Framework defaults | `<DOTBOT_HOME>/content/settings/settings.default.json` | Baseline for all projects |
| 2 — Project override | `.bot/content/settings/settings.default.json` | Project-specific defaults (tracked) |
| 3 — User settings | `~/.config/dotbot/user-settings.json` | Per-developer overrides (not tracked) |
| 4 — Control state | `.bot/.control/settings.json` | Runtime state: active workflow, stacks, instance_id |

---

## Workflow & stack model

### Adding a workflow

```powershell
dotbot workflow add start-from-jira
```

This records the active workflow in `.control/settings.json`. The workflow's content is resolved lazily from `DOTBOT_HOME` — no files are copied unless the workflow ships an `overrides/` subtree.

### Workflow inheritance

```yaml
# .bot/content/workflows/my-workflow/workflow.yaml
name: my-workflow
extends: start-from-prompt
phases:
  - name: spec
    # overrides the spec phase from the base workflow
```

### MCP tool discovery

The runtime walks both `tools/` (v4 layout) and `systems/mcp/tools/` (legacy layout) under each workflow source, so existing v3-style registries continue to work.

---

## Migration from v3

See [`MIGRATING.md`](../MIGRATING.md) at the repo root for the full step-by-step guide. The short version:

1. Archive `~/dotbot` (your v3 copy)
2. Clone afresh: `git clone https://github.com/andresharpe/dotbot ~/dotbot`
3. Run `pwsh ~/dotbot/bootstrap.ps1`
4. Set `$env:DOTBOT_HOME = "~/dotbot"` in your shell profile
5. Per project: `git rm -r .bot/src .bot/content .bot/settings .bot/recipes .bot/hooks`
6. Remove `.bot/.manifest.json`, `.bot/go.ps1`, `.bot/init.ps1`
7. Run `dotbot init` to create the v4 `.bot/` structure
8. Run `dotbot status` to confirm

The `~/dotbot/user-settings.json → ~/.config/dotbot/user-settings.json` move happens automatically on first run.

---

*Last updated: 2026-07-03*
*See also: [MIGRATING.md](../MIGRATING.md) · [AGENTS.md](../AGENTS.md) · [Release Notes](release-notes/v4.0.1.md)*
