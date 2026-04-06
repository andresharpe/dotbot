# Phase 5: Rich Decision Records

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Status: ✅ Substantially Complete (PR #62, 2026-03-15)

~90% aligned with spec. Decisions implemented as first-class entities throughout the system.

**Delivered:**
- 7 MCP tools: `decision-create`, `decision-get`, `decision-list`, `decision-update`, `decision-mark-accepted`, `decision-mark-deprecated`, `decision-mark-superseded`
- Full Dashboard "Decisions" tab with create/edit/status-change modals
- Workflow integration: new `01b-generate-decisions.md` step, updated `03a-plan-task-groups.md` and `03b-expand-task-group.md`
- Task integration: `98-analyse-task.md` maps decision constraints, `99-autonomous-task.md` treats decisions as non-negotiable, `task-get-context` returns linked decisions
- Comprehensive tests in `tests/Test-Components.ps1`
- Storage: `workspace/adrs/{proposed,accepted,deprecated,superseded}/` with status-based subdirectories and `.gitkeep` files

**Remaining gaps:**
1. **`decision-link` tool** — Spec calls for a standalone linking tool. Currently handled via `decision-update` (updating `related_task_ids`/`related_decision_ids` fields). Functionally equivalent.
2. **Event bus integration** — Spec requires `decision.created`, `decision.accepted`, `decision.superseded` events. Not implemented (Phase 4 dependency — event bus doesn't exist yet). Wire up when Phase 4 ships.
3. **Init-time directory creation** — `workspace/decisions/` not created during `dotbot init`. Uses profile template `.gitkeep` dirs instead. Functionally equivalent.
4. **Directory naming** — Implementation uses `workspace/adrs/` with status subdirs; spec below says `workspace/decisions/` flat. Minor divergence to reconcile.

---

## Directory
`.bot/workspace/adrs/{proposed,accepted,deprecated,superseded}/` *(implemented; spec originally said `workspace/decisions/`)*

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
**Spec (5):** `decision-create`, `decision-list`, `decision-get`, `decision-update`, `decision-link`

**Implemented (7):** `decision-create`, `decision-get`, `decision-list`, `decision-update`, `decision-mark-accepted`, `decision-mark-deprecated`, `decision-mark-superseded` — more granular status transitions than spec; `decision-link` not yet implemented (handled via `decision-update`).

## Prompt integration
- `98-analyse-task.md`: check existing decisions for context
- `99-autonomous-task.md`: record decisions when making choices

## Web UI
- New "Decisions" tab
- `systems/ui/modules/DecisionAPI.psm1`

## Events
- `decision.created`, `decision.accepted`, `decision.superseded` events emitted via bus
- **Not yet implemented** — deferred to Phase 4 (Event Bus) delivery

## Files
- Create: `systems/mcp/tools/decision-{create,list,get,update,link}/` (5 tools) — *Implemented 7 tools (no link, added mark-accepted/deprecated/superseded)*
- Create: `systems/ui/modules/DecisionAPI.psm1` — *Done*
- Modify: `prompts/workflows/98-analyse-task.md`, `99-autonomous-task.md` — *Done*
- New: `prompts/workflows/01b-generate-decisions.md` — *Done (not in original spec)*
- Add to init: `workspace/decisions/` — *Uses profile template `workspace/adrs/` with gitkeep dirs instead*
