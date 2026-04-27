# Phase 6: Restructure Profiles — Separate Stacks from Workflows

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Directory restructuring
```
profiles/         → stacks only
  default/        → base (always applied)
  dotnet/         → type: stack
  dotnet-blazor/  → type: stack (extends: dotnet)
  dotnet-ef/      → type: stack (extends: dotnet)

workflows/        → NEW top-level dir
  default/        → base workflow files (00-05, 90-91, 98-99)
  start-from-jira/
  start-from-pr/
```

## CLI
- `dotbot init --profile dotnet` — stacks (unchanged)
- `dotbot run start-from-jira` — launch workflow (NEW)
- `dotbot workflows` — list available (NEW)

## Workflow definition (`workflow.yaml`)
```yaml
name: start-from-jira
description: Research-driven initiative workflow
requires_stacks: []
mcp_tools:
  - atlassian-download
  - repo-clone
phases:
  - id: jira-context
    name: Fetch Jira Context
    type: llm
    prompt_file: 00-interview.md
```

Phase definitions move from `settings.default.json` into `workflow.yaml`.

## Init changes
- `init-project.ps1` handles default + stacks only
- Base workflow files always installed
- No workflow replacement at init

## Files
- Move: `profiles/start-from-jira/` → `workflows/start-from-jira/`
- Move: `profiles/start-from-pr/` → `workflows/start-from-pr/`
- Modify: `scripts/init-project.ps1`
- Create: `systems/runtime/modules/WorkflowRegistry.psm1`
- Modify: `install.ps1`
