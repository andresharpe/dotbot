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
  kickstart-via-jira/
  kickstart-via-pr/
```

## CLI
- `dotbot init --profile dotnet` — stacks (unchanged)
- `dotbot run kickstart-via-jira` — launch workflow (NEW)
- `dotbot workflows` — list available (NEW)

## Workflow definition (`workflow.yaml`)
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

## Init changes
- `init-project.ps1` handles default + stacks only
- Base workflow files always installed
- No workflow replacement at init

## Files
- Move: `profiles/kickstart-via-jira/` → `workflows/kickstart-via-jira/`
- Move: `profiles/kickstart-via-pr/` → `workflows/kickstart-via-pr/`
- Modify: `scripts/init-project.ps1`
- Create: `systems/runtime/modules/WorkflowRegistry.psm1`
- Modify: `install.ps1`
