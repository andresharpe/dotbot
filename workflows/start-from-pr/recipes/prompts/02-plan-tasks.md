---
name: Plan Tasks From PR
description: Create follow-up tasks from pull request context using task_create_bulk
version: 1.0
---

# Plan Tasks From Pull Request Context

Create a small, actionable task roadmap from the pull request context.

## Inputs

Read these files first:

```text
Read({ file_path: ".bot/workspace/product/briefing/pr-context.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
Read({ file_path: ".bot/workspace/product/roadmap-overview.md" })
```

## Task Creation Rules

Use `mcp__dotbot__task_create_bulk` to create between 3 and 8 tasks.

Every task must:
- Be directly grounded in the PR description, linked issues, or changed files.
- Be small enough to execute in one focused session.
- Use one of these categories only: `analysis`, `documentation`, `implementation`, `infrastructure`.
- Include concrete acceptance criteria and steps.

Task shaping guidance:
- Create `analysis` tasks when the PR leaves unresolved impact, scope, or dependency questions.
- Create `implementation` tasks for clearly implied code work that is not complete yet.
- Create `documentation` tasks for rollout notes, ADRs, release notes, or stakeholder-facing artifacts the PR suggests.
- Create `infrastructure` tasks only when the diff or linked issues show CI, deployment, config, or environment changes.

Prefer a dependency chain only when one task clearly blocks another. Independent workstreams should have no dependencies.

## Output Contract

Call:

```text
mcp__dotbot__task_create_bulk({ tasks: [...] })
```

Each task should look like:

```json
{
  "name": "Clear action-oriented task name",
  "description": "What needs to happen and why, grounded in the PR context.",
  "category": "analysis",
  "priority": 10,
  "effort": "S",
  "dependencies": [],
  "acceptance_criteria": [
    "Outcome 1",
    "Outcome 2"
  ],
  "steps": [
    "Step 1",
    "Step 2"
  ]
}
```

## After Creation

Verify that:
- At least one task was created.
- No task is generic or detached from the PR context.
- The created tasks cover the main workstreams from `roadmap-overview.md`.

Do not execute the tasks in this phase. Only create them.
