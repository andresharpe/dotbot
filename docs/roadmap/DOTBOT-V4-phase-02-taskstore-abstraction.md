# Phase 2: TaskStore Abstraction

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Create `TaskStore.psm1`
- **Path:** `profiles/default/systems/mcp/modules/TaskStore.psm1`
- Functions:
  - `Move-TaskState -TaskId <id> -From <status> -To <status>` — atomic, validated
  - `Get-TaskByIdOrSlug -Identifier <string>` — unified lookup
  - `New-TaskRecord -Properties <hashtable>` — create with defaults
  - `Update-TaskRecord -TaskId <id> -Updates <hashtable>` — merge-update
- `TaskIndexCache.psm1` becomes read-only query layer
- All `task-mark-*` tools use `Move-TaskState`

## Files
- Create: `profiles/default/systems/mcp/modules/TaskStore.psm1`
- Modify: `profiles/default/systems/mcp/tools/task-mark-*/script.ps1` (7 tools)
- Modify: `profiles/default/systems/mcp/modules/TaskIndexCache.psm1`
