# Phase 5: Rich Decision Records

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Directory
`.bot/workspace/decisions/`

## Decision JSON format
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

## MCP Tools
- `decision-create`, `decision-list`, `decision-get`, `decision-update`, `decision-link`

## Prompt integration
- `98-analyse-task.md`: check existing decisions for context
- `99-autonomous-task.md`: record decisions when making choices

## Web UI
- New "Decisions" tab
- `systems/ui/modules/DecisionAPI.psm1`

## Events
- `decision.created`, `decision.accepted`, `decision.superseded` events emitted via bus

## Files
- Create: `systems/mcp/tools/decision-{create,list,get,update,link}/` (5 tools)
- Create: `systems/ui/modules/DecisionAPI.psm1`
- Modify: `prompts/workflows/98-analyse-task.md`, `99-autonomous-task.md`
- Add to init: `workspace/decisions/`
