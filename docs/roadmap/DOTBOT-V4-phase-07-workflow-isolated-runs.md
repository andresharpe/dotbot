# Phase 7: Workflows as Isolated Runs

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Concept
When `dotbot run start-from-jira` is invoked:
1. Creates a **workflow run** at `.bot/workspace/workflow-runs/{wfrun-id}.json`
2. Generates a **task per phase** in a run-specific task queue
3. Dependencies encode phase ordering
4. Standard analysis/execution processes pick them up
5. UI shows the run as a self-contained entity

## Workflow Run record
```json
{
  "id": "wfrun-abc123",
  "workflow": "start-from-jira",
  "status": "running|paused|completed|failed",
  "started_at": "2026-03-14T10:00:00Z",
  "phases_total": 15,
  "phases_completed": 3,
  "current_phase": "plan-atlassian-research",
  "task_ids": ["task-001", "task-002"]
}
```

## Task queue isolation
- Workflow tasks: `.bot/workspace/workflow-runs/{wfrun-id}/tasks/{status}/`
- Regular tasks: `.bot/workspace/tasks/{status}/`
- Each queue operates independently

## MCP tools
- `workflow-run`, `workflow-list`, `workflow-status`, `workflow-pause`, `workflow-resume`

## Events
- `workflow.started`, `workflow.phase_completed`, `workflow.completed` emitted via bus

## Files
- Create: `systems/mcp/tools/workflow-{run,list,status}/`
- Create: `systems/runtime/modules/WorkflowRunner.psm1`
- Add to init: `workspace/workflow-runs/`
- Modify: task system to support `workflow_run_id`
