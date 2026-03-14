# Dotbot v3 Major Refactor Plan

## Context

Dotbot v3 has grown organically and now suffers from architectural tensions: profiles conflate stacks and workflows, task/process management is brittle and monolithic, workflows are locked at init time, there's no decision tracking, logging is ad-hoc, and the event/feedback system is tightly coupled. This plan addresses all of these while establishing a clean component architecture.

---

## Component Architecture

### Overview

Dotbot is composed of five distinct architectural components. Each has a clear identity and responsibility boundary.

```
┌─────────────────────────────────────────────────────────────────┐
│                        MOTHERSHIP                               │
│  Fleet management, cross-org monitoring, question delivery      │
│  (.NET server — server/)                                        │
└──────────────┬──────────────────────────────────────────────────┘
               │ API (heartbeat, sync, questions)
    ┌──────────┴──────────┐
    │   Per-project .bot   │  ← "Outpost" (the local workspace)
    │                      │
    │  ┌────────────────┐  │
    │  │   DASHBOARD    │  │  Local web UI (systems/ui/)
    │  └───────┬────────┘  │
    │          │ events     │
    │  ┌───────┴────────┐  │
    │  │   EVENT BUS    │  │  Internal pub/sub for dotbot events
    │  └───┬────┬───┬───┘  │
    │      │    │   │       │
    │  ┌───┘ ┌──┘ ┌─┘      │
    │  │     │    │         │
    │  ▼     ▼    ▼         │
    │ Aether Webhooks Mothership│  ← Event sinks (plugins)
    │ (Hue)  (POST)  (notify)   │
    │                      │
    │  ┌────────────────┐  │
    │  │    RUNTIME     │  │  Process launcher, task loop, worktrees
    │  └───────┬────────┘  │
    │          │            │
    │  ┌───────┴────────┐  │
    │  │   MCP SERVER   │  │  Tool discovery + execution
    │  └────────────────┘  │
    └──────────────────────┘
```

### 1. Outpost (`.bot/`)

The **Outpost** is the per-project workspace directory. It's where dotbot lives in each repository — the local installation of all dotbot capabilities.

**Contains:**
- `systems/` — runtime, MCP server, UI server
- `prompts/` — agents, skills, workflows
- `workspace/` — tasks, plans, decisions, sessions, workflow runs, product docs
- `defaults/` — settings
- `.control/` — runtime state, logs, processes (gitignored)
- `hooks/` — verification, dev lifecycle, automation scripts

**Key property:** Each outpost is self-contained. You can have multiple repos each with their own outpost, all managed independently or connected to a mothership.

**Architectural name for docs:** "Outpost" — evokes a self-sufficient station that can operate autonomously but reports to a mothership.

### 2. Runtime

The process orchestration engine that drives all work.

**Current:** `launch-process.ps1` (2,924 lines) — monolithic
**Target:** Decomposed into ProcessRegistry + TaskLoop + per-type handlers

**Responsibilities:**
- Process lifecycle (create, track, stop, clean up)
- Task loop (get-next, invoke LLM, check completion, retry)
- Worktree isolation (branch per task, squash-merge on completion)
- Provider CLI abstraction (Claude, Codex, Gemini)

### 3. MCP Server

The tool layer — auto-discovers and executes tools for the LLM.

**Current:** `dotbot-mcp.ps1` (261 lines) + 26 tools in `tools/*/`
**Target:** Same architecture, expanded with workflow/decision/event tools

**Key modules:**
- `TaskIndexCache.psm1` — read-only task query cache
- `TaskStore.psm1` — (NEW) atomic task state transitions
- `SessionTracking.psm1` — session state
- `NotificationClient.psm1` — mothership communication

### 4. Dashboard

The local web UI for monitoring and control.

**Current:** `server.ps1` (1,533 lines) + 9 modules + vanilla JS frontend
**Target:** Same architecture, extended with new tabs (Decisions, Workflows, Fleet)

### 5. Mothership

The centralized .NET server for fleet-wide management.

**Current:** `server/` — ASP.NET Core app with Teams/Email/Jira question delivery
**Target:** Extended to full fleet management: instance registry, heartbeat monitoring, cross-org decision routing, fleet dashboard

### 6. Event Bus

**NEW.** Internal pub/sub system for dotbot events. Currently, Aether is hardwired into the UI's polling loop. The mothership notifications are triggered directly from MCP tools. These need to be decoupled.

**Event types:**
- `task.started`, `task.completed`, `task.failed`
- `process.started`, `process.stopped`
- `decision.created`, `decision.accepted`
- `workflow.started`, `workflow.phase_completed`, `workflow.completed`
- `activity.write`, `activity.edit`, `activity.bash`
- `error`, `rate_limit`

**Event sinks (plugins):**
- **Aether** — Hue lights (existing, refactored to subscribe to events)
- **Webhooks** — POST to arbitrary URLs (NEW)
- **Mothership** — sync events to central server (existing NotificationClient, refactored)
- **Future:** WLED, Nanoleaf, sound, Slack, desktop notifications

### 7. Stacks & Workflows

**Stacks** = composable technology overlays (dotnet, dotnet-blazor, dotnet-ef).
**Workflows** = launchable multi-phase pipelines (kickstart-via-jira, kickstart-via-pr).

These are the two "extension" mechanisms, cleanly separated.

---

## Phase 1: Structured Logging Module (Foundation)

**Why first:** Every subsequent phase benefits from proper logging.

### Create `DotBotLog.psm1`
- **Path:** `profiles/default/systems/runtime/modules/DotBotLog.psm1`
- Functions:
  - `Write-BotLog -Level {Debug|Info|Warn|Error|Fatal} -Message <string> -Context <hashtable> -Exception <ErrorRecord>`
  - `Initialize-DotBotLog -LogDir <path> -MinLevel <level>`
  - `Rotate-DotBotLog` — removes files older than 7 days
- Output: structured JSONL to `.bot/.control/logs/dotbot-{date}.jsonl`
- Each line: `{ts, level, msg, process_id, task_id, phase, pid, error, stack}`
- Activity log integration: Info+ events also go to `activity.jsonl` for backward compat
- `Write-Diag` becomes a thin wrapper: `Write-BotLog -Level Debug`
- `Write-ActivityLog` delegates internally to `Write-BotLog`

### Settings addition
```json
"logging": {
  "console_level": "Info",
  "file_level": "Debug",
  "retention_days": 7,
  "max_file_size_mb": 50
}
```

### Replace silent catch blocks
All 25+ `catch {}` blocks become:
```powershell
catch { Write-BotLog -Level Warn -Message "..." -Exception $_ }
```

### Files
- Create: `profiles/default/systems/runtime/modules/DotBotLog.psm1`
- Modify: `profiles/default/defaults/settings.default.json`
- Modify: `profiles/default/systems/runtime/launch-process.ps1`
- Modify: `profiles/default/systems/runtime/modules/ui-rendering.ps1`
- Add to init: `.bot/.control/logs/`

---

## Phase 2: TaskStore Abstraction

### Create `TaskStore.psm1`
- **Path:** `profiles/default/systems/mcp/modules/TaskStore.psm1`
- Functions:
  - `Move-TaskState -TaskId <id> -From <status> -To <status>` — atomic, validated
  - `Get-TaskByIdOrSlug -Identifier <string>` — unified lookup
  - `New-TaskRecord -Properties <hashtable>` — create with defaults
  - `Update-TaskRecord -TaskId <id> -Updates <hashtable>` — merge-update
- `TaskIndexCache.psm1` becomes read-only query layer
- All `task-mark-*` tools use `Move-TaskState`

### Files
- Create: `profiles/default/systems/mcp/modules/TaskStore.psm1`
- Modify: `profiles/default/systems/mcp/tools/task-mark-*/script.ps1` (7 tools)
- Modify: `profiles/default/systems/mcp/modules/TaskIndexCache.psm1`

---

## Phase 3: Break Up launch-process.ps1

### New structure
```
systems/runtime/
  launch-process.ps1              # ~200 lines: parse args, preflight, dispatch
  modules/
    ProcessRegistry.psm1          # Process CRUD, locking, activity logging
    TaskLoop.psm1                 # Shared task iteration
    ProcessTypes/
      Invoke-AnalysisProcess.ps1
      Invoke-ExecutionProcess.ps1
      Invoke-WorkflowProcess.ps1
      Invoke-KickstartProcess.ps1
      Invoke-PromptProcess.ps1    # planning, commit, task-creation
```

### ProcessRegistry.psm1
Extracted from launch-process.ps1:
- `New-ProcessId`, `Write-ProcessFile`, `Write-ProcessActivity`
- `Test-ProcessStopSignal`, `Test-ProcessLock`, `Set-ProcessLock`, `Remove-ProcessLock`
- `Test-Preflight`

### TaskLoop.psm1
Shared iteration pattern (currently duplicated 3x in analysis/execution/workflow):
- `Invoke-TaskLoop -Strategy <scriptblock> -OnComplete <scriptblock>`
- `Wait-ForTasks` — wait-with-heartbeat
- `Invoke-WithRetry` — retry-with-rate-limit

### Files
- Gut: `launch-process.ps1` → ~200 line dispatcher
- Create: `modules/ProcessRegistry.psm1`
- Create: `modules/TaskLoop.psm1`
- Create: `modules/ProcessTypes/Invoke-{Analysis,Execution,Workflow,Kickstart,Prompt}Process.ps1`

---

## Phase 4: Event Bus

### Design
A lightweight in-process event system for the outpost.

**Path:** `profiles/default/systems/runtime/modules/EventBus.psm1`

```powershell
# Publishing events
Publish-DotBotEvent -Type "task.completed" -Data @{ task_id = $id; name = $name }

# Subscribing (plugins register at startup)
Register-DotBotEventSink -Name "aether" -Handler { param($Event) ... }
Register-DotBotEventSink -Name "webhooks" -Handler { param($Event) ... }
Register-DotBotEventSink -Name "mothership" -Handler { param($Event) ... }
```

**Event envelope:**
```json
{
  "id": "evt-abc123",
  "type": "task.completed",
  "timestamp": "2026-03-14T10:00:00Z",
  "source": "runtime",
  "data": { "task_id": "...", "name": "..." }
}
```

**File-based event log:** `.bot/.control/events.jsonl` — all events are persisted for replay and debugging.

**Plugin discovery:** Event sinks are loaded from `systems/events/sinks/` — each subfolder contains a `sink.psm1` with `Register-*` and `Invoke-*` functions.

```
systems/events/
  EventBus.psm1
  sinks/
    aether/sink.psm1       # Refactored from AetherAPI.psm1
    webhooks/sink.psm1     # NEW — POST events to configured URLs
    mothership/sink.psm1   # Refactored from NotificationClient.psm1
```

### Aether refactor
- Currently: `AetherAPI.psm1` (UI module) + `aether.js` (frontend) poll state and react
- Target: `aether/sink.psm1` subscribes to events via the bus. The UI frontend (`aether.js`) receives events via the existing polling/SSE mechanism and drives the Hue API calls.
- The Hue bridge interaction stays client-side (browser → API proxy → bridge) since it needs LAN access

### Webhook sink
```json
"webhooks": {
  "enabled": true,
  "endpoints": [
    {
      "url": "https://hooks.example.com/dotbot",
      "events": ["task.completed", "decision.created"],
      "secret": "hmac-secret"
    }
  ]
}
```

### Files
- Create: `profiles/default/systems/events/EventBus.psm1`
- Create: `profiles/default/systems/events/sinks/aether/sink.psm1`
- Create: `profiles/default/systems/events/sinks/webhooks/sink.psm1`
- Create: `profiles/default/systems/events/sinks/mothership/sink.psm1`
- Modify: `profiles/default/systems/ui/modules/AetherAPI.psm1` (delegate to sink)
- Modify: `profiles/default/systems/mcp/modules/NotificationClient.psm1` (delegate to sink)
- Modify: Runtime process types to emit events at lifecycle points
- Settings: Add `events` section to `settings.default.json`

---

## Phase 5: Rich Decision Records

### Directory
`.bot/workspace/decisions/`

### Decision JSON format
```json
{
  "id": "dec-a1b2c3d4",
  "title": "Use PostgreSQL for primary data store",
  "type": "architecture|business|technical|process",
  "status": "proposed|accepted|deprecated|superseded",
  "date": "2026-03-14",
  "context": "Why this decision was needed",
  "decision": "What was decided",
  "consequences": "What follows",
  "alternatives_considered": [
    {"option": "SQL Server", "reason_rejected": "Cost"}
  ],
  "stakeholders": ["@andre"],
  "related_task_ids": [],
  "related_decision_ids": [],
  "supersedes": null,
  "superseded_by": null,
  "tags": ["database"],
  "impact": "high|medium|low"
}
```

### MCP Tools
- `decision-create`, `decision-list`, `decision-get`, `decision-update`, `decision-link`

### Prompt integration
- `98-analyse-task.md`: check existing decisions for context
- `99-autonomous-task.md`: record decisions when making choices

### Web UI
- New "Decisions" tab
- `systems/ui/modules/DecisionAPI.psm1`

### Events
- `decision.created`, `decision.accepted`, `decision.superseded` events emitted via bus

### Files
- Create: `systems/mcp/tools/decision-{create,list,get,update,link}/` (5 tools)
- Create: `systems/ui/modules/DecisionAPI.psm1`
- Modify: `prompts/workflows/98-analyse-task.md`, `99-autonomous-task.md`
- Add to init: `workspace/decisions/`

---

## Phase 6: Restructure Profiles — Separate Stacks from Workflows

### Directory restructuring
```
profiles/         → stacks only
  default/        → base (always applied)
  dotnet/         → type: stack
  dotnet-blazor/  → type: stack (extends: dotnet)
  dotnet-ef/      → type: stack (extends: dotnet)

workflows/        → NEW top-level dir
  default/        → base workflow files (00-05, 90-91, 98-99)
  kickstart-via-jira/
  kickstart-via-pr/
```

### CLI
- `dotbot init --profile dotnet` — stacks (unchanged)
- `dotbot run kickstart-via-jira` — launch workflow (NEW)
- `dotbot workflows` — list available (NEW)

### Workflow definition (`workflow.yaml`)
```yaml
name: kickstart-via-jira
description: Research-driven initiative workflow
requires_stacks: []
mcp_tools:
  - atlassian-download
  - repo-clone
phases:
  - id: jira-context
    name: Fetch Jira Context
    type: llm
    prompt_file: 00-kickstart-interview.md
```

Phase definitions move from `settings.default.json` into `workflow.yaml`.

### Init changes
- `init-project.ps1` handles default + stacks only
- Base workflow files always installed
- No workflow replacement at init

### Files
- Move: `profiles/kickstart-via-jira/` → `workflows/kickstart-via-jira/`
- Move: `profiles/kickstart-via-pr/` → `workflows/kickstart-via-pr/`
- Modify: `scripts/init-project.ps1`
- Create: `systems/runtime/modules/WorkflowRegistry.psm1`
- Modify: `install.ps1`

---

## Phase 7: Workflows as Isolated Runs

### Concept
When `dotbot run kickstart-via-jira` is invoked:
1. Creates a **workflow run** at `.bot/workspace/workflow-runs/{wfrun-id}.json`
2. Generates a **task per phase** in a run-specific task queue
3. Dependencies encode phase ordering
4. Standard analysis/execution processes pick them up
5. UI shows the run as a self-contained entity

### Workflow Run record
```json
{
  "id": "wfrun-abc123",
  "workflow": "kickstart-via-jira",
  "status": "running|paused|completed|failed",
  "started_at": "2026-03-14T10:00:00Z",
  "phases_total": 15,
  "phases_completed": 3,
  "current_phase": "plan-atlassian-research",
  "task_ids": ["task-001", "task-002"]
}
```

### Task queue isolation
- Workflow tasks: `.bot/workspace/workflow-runs/{wfrun-id}/tasks/{status}/`
- Regular tasks: `.bot/workspace/tasks/{status}/`
- Each queue operates independently

### MCP tools
- `workflow-run`, `workflow-list`, `workflow-status`, `workflow-pause`, `workflow-resume`

### Events
- `workflow.started`, `workflow.phase_completed`, `workflow.completed` emitted via bus

### Files
- Create: `systems/mcp/tools/workflow-{run,list,status}/`
- Create: `systems/runtime/modules/WorkflowRunner.psm1`
- Add to init: `workspace/workflow-runs/`
- Modify: task system to support `workflow_run_id`

---

## Phase 8: Mothership Fleet Management

### Current state
- `server/` — .NET app for question delivery (Teams, Email, Jira)
- `NotificationClient.psm1` — outpost-side client for sending questions, polling responses
- Settings: `mothership.enabled`, `server_url`, `api_key`, `channel`, `recipients`

### Target: Full fleet management

#### Instance Registry
Each outpost registers with the mothership on startup:
```json
POST /api/fleet/register
{
  "instance_id": "guid",
  "project_name": "my-app",
  "project_description": "...",
  "stacks": ["dotnet", "dotnet-blazor"],
  "active_workflows": ["kickstart-via-jira"],
  "version": "3.x.x"
}
```

#### Heartbeat
Outposts send periodic heartbeats:
```json
POST /api/fleet/{instance_id}/heartbeat
{
  "status": "active|idle|error",
  "tasks": { "todo": 5, "in_progress": 1, "done": 12 },
  "active_processes": 2,
  "decisions_pending": 1,
  "last_activity": "2026-03-14T10:00:00Z"
}
```

#### Fleet Dashboard
New server-side dashboard showing:
- All registered outposts with status (active/idle/stale)
- Task counts across the fleet
- Pending decisions that need human input
- Active workflow runs
- Cross-org decision routing (a decision in one outpost can be routed to stakeholders in another)

#### Decision Sync
Decisions with `impact: high` or `stakeholders` that include cross-org references are synced to the mothership for routing:
```json
POST /api/fleet/{instance_id}/decisions
{
  "decision": { ... full decision record ... },
  "routing": { "stakeholders": ["andre@org.com"], "urgency": "normal" }
}
```

#### Event Forwarding
The mothership event sink forwards selected events to the central server:
```json
POST /api/fleet/{instance_id}/events
{
  "events": [
    { "type": "task.completed", "timestamp": "...", "data": { ... } }
  ]
}
```

### Outpost-side changes
- Enhance `NotificationClient.psm1` → `MothershipClient.psm1` with:
  - `Register-WithMothership`
  - `Send-Heartbeat`
  - `Sync-Decisions`
  - `Forward-Events`
- The mothership event sink (`sinks/mothership/sink.psm1`) handles event forwarding
- Heartbeat integrated into the dashboard's polling cycle

### Server-side changes
- New API controllers: `FleetController`, `DecisionRoutingController`
- New dashboard pages: Fleet overview, cross-org decision queue
- Instance health tracking with stale detection
- Decision routing engine (match stakeholders to delivery channels)

### Settings evolution
```json
"mothership": {
  "enabled": false,
  "server_url": "",
  "api_key": "",
  "channel": "teams",
  "recipients": [],
  "project_name": "",
  "project_description": "",
  "heartbeat_interval_seconds": 60,
  "sync_tasks": true,
  "sync_questions": true,
  "sync_decisions": true,
  "sync_events": ["task.completed", "workflow.completed", "decision.created"],
  "fleet_dashboard": true
}
```

### Files
- Rename: `NotificationClient.psm1` → `MothershipClient.psm1` (with backward compat alias)
- Create: `systems/events/sinks/mothership/sink.psm1`
- Modify: `server/src/Dotbot.Server/` — new controllers, services, dashboard pages
- Modify: `profiles/default/defaults/settings.default.json`

---

## Phase 9: Additional Improvements

### 9a. Health Check System
- `scripts/doctor.ps1` — directories, orphaned worktrees, stuck tasks, dead PIDs, CLI availability
- `systems/ui/modules/HealthAPI.psm1`

### 9b. Process Telemetry
- `systems/runtime/modules/Telemetry.psm1` — per-task metrics
- `.bot/.control/telemetry/` as JSONL
- Emits events via bus

### 9c. Idempotent Init
- `dotbot init` works without `--force` — detects state, updates only newer files, preserves workspace

### 9d. Configuration Validation
- `systems/runtime/modules/ConfigValidator.psm1` — schema validation for settings, workflow.yaml, task JSON

---

## Implementation Order

| # | Phase | Effort | Risk | Dependencies |
|---|-------|--------|------|--------------|
| 1 | Structured Logging | S-M | Low | None |
| 2 | TaskStore Abstraction | S | Low | None |
| 3 | Break up launch-process.ps1 | L | Medium | 1, 2 |
| 4 | Event Bus | M | Medium | 1 |
| 5 | Rich Decision Records | S-M | Low | 4 (for events) |
| 6 | Restructure Profiles | M | Medium | None |
| 7 | Workflows as Isolated Runs | L | High | 3, 6 |
| 8 | Mothership Fleet Management | L | Medium | 4, 5 |
| 9 | Additional improvements | S each | Low | 1-8 |

**Parallel tracks:**
- Track A: 1 → 2 → 3 → 7 (runtime/task/workflow)
- Track B: 4 → 5 → 8 (events/decisions/mothership)
- Track C: 6 (profiles — independent)
- Track D: 9 (polish — after everything)

---

## Verification

After each phase:
1. `pwsh install.ps1`
2. `pwsh tests/Run-Tests.ps1` (layers 1-3)
3. Phase-specific checks:
   - Phase 1: Structured JSONL in logs, no silent catches
   - Phase 2: Task state transitions atomic and validated
   - Phase 3: All process types dispatch correctly
   - Phase 4: Events published and sinks receive them
   - Phase 5: Decisions CRUD + UI tab
   - Phase 6: `dotbot init --profile dotnet` works, workflows separate
   - Phase 7: `dotbot run` creates isolated run with tasks
   - Phase 8: Outpost registers with mothership, heartbeats flow
   - Phase 9: `dotbot doctor` reports health

## Key Files Referenced

| File | Lines | Role |
|------|-------|------|
| `profiles/default/systems/runtime/launch-process.ps1` | 2,924 | Monolith to decompose |
| `scripts/init-project.ps1` | 977 | Init to simplify |
| `profiles/default/systems/mcp/modules/TaskIndexCache.psm1` | — | Task query layer |
| `profiles/default/systems/runtime/modules/ui-rendering.ps1` | — | Activity logging |
| `profiles/default/systems/runtime/ClaudeCLI/ClaudeCLI.psm1` | 1,232 | CLI wrapper |
| `profiles/default/defaults/settings.default.json` | 77 | Settings hub |
| `profiles/default/systems/ui/server.ps1` | 1,533 | Dashboard server |
| `profiles/default/systems/ui/modules/AetherAPI.psm1` | 290 | Hue bridge integration |
| `profiles/default/systems/mcp/modules/NotificationClient.psm1` | 350 | Mothership client |
| `profiles/default/systems/ui/static/modules/aether.js` | 930 | Aether frontend |
| `server/src/Dotbot.Server/` | — | Mothership .NET server |
