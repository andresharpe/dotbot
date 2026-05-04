# Glossary

Domain terms used in the dotbot codebase. The reviewer uses this file to **avoid** flagging deliberate naming as misnamings. If a term appears here, the agent treats it as authoritative.

Bootstrap drafted these entries by mining repeated identifiers, function/module names, READMEs, and `CLAUDE.md`. Every drafted entry is marked `<!-- TODO: confirm -->`. Edit definitions, remove entries, add new ones.

## Format

```markdown
### TermName

One-sentence definition. Plain language.

Used in: `path/to/file.ps1:line`, `path/to/another.ps1:line`
Related: TermB, TermC
```

## Entries

<!-- TODO: confirm or replace all entries below. Bootstrap inferred these from repeated usage. -->

### dotbot

The framework itself. The PSGallery module (`dotbot.psd1`) and the `~/dotbot` installation it deploys to a developer's machine.

Used in: `dotbot.psd1`, `dotbot.psm1`, `install.ps1`, `README.md`
Related: bot-root, .bot, Invoke-Dotbot

### .bot

The per-project directory created by `dotbot init`. Holds the framework copy (`core/`, `workflows/`), workspace state (`workspace/`), and runtime control (`.control/`). Tracked in target repos. Gitignored in the dotbot repo itself.

Used in: `core/runtime/modules/WorktreeManager.psm1`, `CLAUDE.md`, `README.md`
Related: bot-root, control-dir, workspace

### bot-root / BotRoot

The path to a project's `.bot/` directory. Standard parameter name across runtime modules.

Used in: `core/runtime/modules/SettingsLoader.psm1:71`, many MCP tools
Related: .bot, repo-root

### Task

A unit of AI-assisted work. Has a state file (frontmatter + markdown body), a state in {todo, analysing, analysed, in-progress, done, needs-input, skipped}, an optional dependency list, and a per-task git worktree.

Used in: `core/mcp/modules/TaskStore.psm1`, `core/mcp/modules/TaskMutation.psm1`, `core/mcp/tools/task-*/script.ps1`
Related: Task ID, Worktree, two-phase execution

### Task ID / short-id

The 8-character identifier used in branch names (`task/{short-id}-{slug}`), worktree paths, and commit tags (`[task:XXXXXXXX]`).

Used in: `core/runtime/modules/WorktreeManager.psm1`, commit messages
Related: Task, Worktree

### Worktree

A per-task isolated git checkout under `{repo-parent}/worktrees/{repo-name}/task-{short-id}-{slug}/`. Created at analysis start, removed on task completion.

Used in: `core/runtime/modules/WorktreeManager.psm1`, `New-TaskWorktree`, `Complete-TaskWorktree`
Related: Task, Task ID

### Two-phase execution

The dotbot pattern of analysis-first, implementation-second. Phase 1 (`98-analyse-task.md`) explores and builds context; phase 2 (`99-autonomous-task.md`) consumes that context and writes code.

Used in: `core/prompts/98-analyse-task.md`, `core/prompts/99-autonomous-task.md`, `CLAUDE.md`
Related: Task, Recipe, Analysis

### Recipe

The dotbot term for prompt files (post-rename). Lives under `core/recipes/` framework-side and `workflows/<name>/recipes/` workflow-side. Replaces the legacy "prompts" term per issue #100.

Used in: `workflows/*/recipes/`, `CLAUDE.md`
Related: Skill, Agent, Prompt

### Workflow

A start-mode for new dotbot projects. The four built-ins are `start-from-jira`, `start-from-pr`, `start-from-prompt`, `start-from-repo`. Each ships its own recipes, settings, and (sometimes) MCP tools and on-install hook.

Used in: `workflows/*/manifest.yaml`, `workflows/*/workflow.yaml`, `scripts/workflow-add.ps1`, `scripts/workflow-list.ps1`
Related: Recipe, Stack, Manifest

### Stack

A target-language/runtime profile. The repo currently has `stacks/dotnet/` with its own dev hooks and MCP tools. Stacks layer onto a workflow.

Used in: `stacks/dotnet/`, `dotbot init --profile dotnet`
Related: Workflow, Profile

### MCP server / MCP tool

The Model Context Protocol server (`core/mcp/dotbot-mcp.ps1`) that exposes 33 tools to Claude. Each tool lives at `core/mcp/tools/<tool-name>/` with `metadata.yaml` and `script.ps1`. Auto-discovered.

Used in: `core/mcp/dotbot-mcp.ps1`, `core/mcp/tools/`, `.mcp.json`
Related: Tool, MCP, JSON-RPC

### Steering / steering-heartbeat

The operator-whisper interrupt protocol. Allows a human to inject guidance into an autonomous task by writing to a steering file that `steering-heartbeat` polls.

Used in: `core/mcp/tools/steering-heartbeat/`, `core/hooks/scripts/steering.ps1`, `core/prompts/92-steering-protocol.include.md`
Related: Heartbeat, Whisper

### Decision

The dotbot term for ADR (Architecture Decision Record), post-rename. Lives under `.bot/workspace/decisions/` in target projects.

Used in: `core/mcp/tools/decision-*/script.ps1`, `core/ui/modules/DecisionAPI.psm1`, `workflows/*/recipes/`
Related: ADR (legacy), Recipe

### Plan

A task plan: a structured breakdown of what an analysing task intends to do. Stored in workspace alongside the task file.

Used in: `core/mcp/tools/plan-create/`, `core/mcp/tools/plan-update/`, `core/mcp/tools/plan-get/`
Related: Task, Two-phase execution

### Session

A Claude CLI conversation session. dotbot persists session IDs to allow conversation continuity across launches.

Used in: `core/runtime/ClaudeCLI/ClaudeCLI.psm1` (`New-ClaudeSession`), `core/mcp/tools/session-*/script.ps1`, `core/mcp/modules/SessionTracking.psm1`
Related: ClaudeCLI, Provider

### Provider / Coding Agent

The CLI backend used to run AI coding work. Currently Claude, Codex, or Gemini. User-facing UI uses the term "Coding Agent"; internal code uses "Provider".

Used in: `core/runtime/ProviderCLI/ProviderCLI.psm1`, `core/runtime/ProviderCLI/parsers/Parse-*Stream.ps1`
Related: ClaudeCLI, Session, Mock

### Process / process-id

A tracked subprocess of the dotbot runtime. Has a registry entry, lock, activity log, and lifecycle managed by `core/runtime/modules/ProcessRegistry.psm1`. Process types: `task-runner`, `planning`, `commit`, `task-creation`.

Used in: `core/runtime/launch-process.ps1`, `core/runtime/modules/ProcessRegistry.psm1`, `core/ui/modules/ProcessAPI.psm1`
Related: launch-process, ProcessRegistry, task-runner

### task-runner

The post-rename term for the autonomous-task execution loop (formerly "workflow"). Used as a process-type label.

Used in: `core/runtime/launch-process.ps1`
Related: Process, Workflow (legacy meaning), two-phase execution

### Settings

The three-tier configuration system: `settings/settings.default.json` (tracked), `~/dotbot/user-settings.json` (machine-wide), `.control/settings.json` (per-project override). Resolved via `Get-MergedSettings`.

Used in: `core/runtime/modules/SettingsLoader.psm1`, `core/ui/modules/SettingsAPI.psm1`
Related: Defaults (legacy), Merge-DeepSettings, BotRoot

### Control / .control

The gitignored runtime state directory under `.bot/.control/`. Holds process registry, lock files, logs, and the per-project settings override.

Used in: `core/runtime/modules/ProcessRegistry.psm1`, `core/runtime/modules/DotBotLog.psm1`
Related: Workspace, Settings

### Workspace / .bot/workspace

The version-controlled state directory under `.bot/workspace/`. Holds tasks, plans, decisions, product briefing, and research outputs.

Used in: `core/mcp/modules/TaskStore.psm1`, `core/ui/modules/StateBuilder.psm1`
Related: Control, Task, Decision

### Skill

A reusable technical guidance prompt under `core/skills/<name>/`. Distinct from agents (personas) and recipes (workflow-scoped prompts).

Used in: `core/skills/`
Related: Agent, Recipe

### Agent

An AI persona under `core/agents/` (implementer, planner, reviewer, tester). TDD-focused. Distinct from skills.

Used in: `core/agents/`
Related: Skill, Recipe

### Manifest

The YAML descriptor for a workflow, MCP tool, or stack. Tells the framework what to install/expose. Schema is project-specific.

Used in: `workflows/*/manifest.yaml`, `core/mcp/tools/*/metadata.yaml`, `core/mcp/modules/Manifest.psm1`, `core/runtime/modules/ManifestCondition.psm1`
Related: Tool, Workflow, Stack

### Heartbeat

A periodic update written by long-running processes for liveness detection and operator visibility. Distinct from steering-heartbeat (which is the steering poll loop).

Used in: `core/runtime/modules/ConsoleSequenceSanitizer.psm1` (`Update-ProcessHeartbeatFields`), `core/mcp/tools/steering-heartbeat/`
Related: Steering, Process

### needs-input

A task state. The task is paused waiting on a human answer. The MCP tool `task-answer-question` resolves it.

Used in: `core/mcp/tools/task-answer-question/`, `core/runtime/modules/MergeConflictEscalation.psm1`
Related: Task, Steering

### Privacy scan

The gitleaks-based pre-commit verification under `core/hooks/verify/00-privacy-scan.ps1`. Blocks commits that would leak credentials.

Used in: `core/hooks/verify/00-privacy-scan.ps1`, `tests/Test-PrivacyScan.ps1`
Related: Verify hooks

---

<!--
Tips when curating this file:

- The reviewer will not "fix" any term listed here. So if you have a name
  that diverges from PowerShell convention deliberately (e.g. domain noun
  not in Get-Verb), document it here to suppress nags.

- Conversely, if a term is *misused* in the codebase, leave it out of the
  glossary. The conventions agent will flag misuses as findings.

- Definitions should be functional, not prose.

- Cross-link related terms so the reviewer understands the term cluster.
-->
