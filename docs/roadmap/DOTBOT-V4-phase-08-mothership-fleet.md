# Phase 8: Mothership Fleet Management

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Current state
- `server/` — .NET app for question delivery (Teams, Email, Jira)
- `NotificationClient.psm1` — outpost-side client for sending questions, polling responses
- Settings: `mothership.enabled`, `server_url`, `api_key`, `channel`, `recipients`

## Target: Full fleet management + Drone work dispatch

### Instance Registry
Each outpost **and drone** registers with the mothership on startup:
```json
POST /api/fleet/register
{
  "instance_id": "guid",
  "instance_type": "outpost|drone",
  "project_name": "my-app",
  "project_description": "...",
  "stacks": ["dotnet", "dotnet-blazor"],
  "active_workflows": ["start-from-jira"],
  "version": "3.x.x",
  "providers": ["claude", "codex"],
  "max_concurrent": 3
}
```

### Heartbeat
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

### Work Queue (for Drones)
The Mothership maintains a work queue that Drones poll for assignments:
```json
POST /api/fleet/work-queue/enqueue
{
  "type": "workflow-run|task|prompt",
  "priority": 1,
  "repo": {
    "url": "https://github.com/org/repo.git",
    "branch": "main",
    "credentials_ref": "github-pat-01"
  },
  "workflow": "start-from-jira",
  "preferred_provider": "claude",
  "preferred_model": "opus",
  "required_stacks": ["dotnet"],
  "parameters": {},
  "deadline": "2026-03-15T00:00:00Z"
}

GET /api/fleet/work-queue/poll?drone_id={id}
# Returns next matching assignment based on drone capabilities

POST /api/fleet/work-queue/{assignment_id}/complete
{
  "status": "completed|failed",
  "result": { "commits": [...], "pr_url": "...", "decisions": [...] },
  "telemetry": { "duration_seconds": 320, "tokens_used": 150000 }
}
```

**Scheduling logic:** Match assignments to drones based on:
- Required stacks vs drone capabilities
- Preferred provider/model vs drone's available providers
- Current drone load vs max_concurrent
- Priority ordering

### Fleet Dashboard
New server-side dashboard showing:
- All registered outposts **and drones** with status (active/idle/working/stale)
- Task counts across the fleet
- Pending decisions that need human input
- Active workflow runs
- **Drone work queue** — pending, assigned, and completed work items
- **Drone utilization** — load, success rate, average duration per drone
- Cross-org decision routing (a decision in one outpost can be routed to stakeholders in another)

### Decision Sync
Decisions with `impact: high` or `stakeholders` that include cross-org references are synced to the mothership for routing:
```json
POST /api/fleet/{instance_id}/decisions
{
  "decision": { ... full decision record ... },
  "routing": { "stakeholders": ["andre@org.com"], "urgency": "normal" }
}
```

### Event Forwarding
The mothership event sink forwards selected events to the central server:
```json
POST /api/fleet/{instance_id}/events
{
  "events": [
    { "type": "task.completed", "timestamp": "...", "data": { ... } }
  ]
}
```

## Outpost-side changes
- Enhance `NotificationClient.psm1` → `MothershipClient.psm1` with:
  - `Register-WithMothership`
  - `Send-Heartbeat`
  - `Sync-Decisions`
  - `Forward-Events`
- The mothership event sink (`sinks/mothership/sink.psm1`) handles event forwarding
- Heartbeat integrated into the dashboard's polling cycle

## Server-side changes
- New API controllers: `FleetController`, `DecisionRoutingController`, `WorkQueueController`
- New services: `WorkQueueService`, `DroneSchedulerService`, `DroneHealthService`
- New dashboard pages: Fleet overview, cross-org decision queue, drone management, work queue
- Instance health tracking with stale detection (drones get shorter stale threshold)
- Decision routing engine (match stakeholders to delivery channels)
- Work queue persistence (SQLite or file-based for simplicity)

## Settings evolution
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

## Files
- Rename: `NotificationClient.psm1` → `MothershipClient.psm1` (with backward compat alias)
- Create: `systems/events/sinks/mothership/sink.psm1`
- Modify: `server/src/Dotbot.Server/` — new controllers, services, dashboard pages
- Modify: `profiles/default/defaults/settings.default.json`
- Server: Create `WorkQueueController.cs`, `WorkQueueService.cs`, `DroneSchedulerService.cs`
