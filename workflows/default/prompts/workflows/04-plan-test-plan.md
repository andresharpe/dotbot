# Workflow: Plan Test Plan

Generate a project-level QA/UAT test plan from product specifications and the defined task list.

## When to Invoke

Run this workflow **after**:
- `03b-expand-task-group.md` has been executed for all task groups (tasks fully defined), OR
- A change request has been processed via `91-new-tasks.md` and tasks are created

Run this workflow **before** implementation begins. A test plan created mid-sprint is reactive; created up front it shapes what tasks need to deliver.

## Prerequisites Check

Before generating the plan, verify both pillars are in place:

1. **Specifications exist** — confirm at least one of:
   - `.bot/workspace/product/mission.md`
   - `.bot/workspace/product/prd.md`
   - `.bot/workspace/product/change-request-*.md`

2. **Tasks are defined** — call `task_list` and confirm tasks exist with acceptance criteria

If either pillar is missing, stop. Output a gap report:
```
## Prerequisites not met

- [ ] Product specifications: <found / NOT FOUND>
- [ ] Tasks with acceptance criteria: <N tasks found / NOT FOUND>

Action required: complete planning phases 00–03b before generating a test plan.
```

## Execution Steps

### Step 1 — Load product context

Read all available specification files:
```
.bot/workspace/product/mission.md
.bot/workspace/product/tech-stack.md
.bot/workspace/product/entity-model.md
.bot/workspace/product/task-groups.json
.bot/workspace/product/prd.md                  (if present)
.bot/workspace/product/interview-summary.md    (if present)
.bot/workspace/product/change-request-*.md     (all, if present)
```

### Step 2 — Load task context

Call MCP tools to pull the live task queue:
```
task_list           → all tasks, grouped by status
task_get_stats      → counts by category and status
```

For each task group in `task-groups.json`, call `task_list` filtered to that group and collect:
- Task names
- Acceptance criteria
- Categories
- Dependencies

### Step 3 — Invoke write-test-plan skill

Apply the `write-test-plan` skill using all loaded context.

The skill will:
- Map every acceptance criterion to a scenario
- Produce integration / E2E scenario tables per group
- Identify risk areas
- Define test data requirements
- Emit a Definition of Done checklist

### Step 4 — Write output

Write the generated test plan to:
```
.bot/workspace/product/test-plan.md
```

### Step 5 — Validate coverage

After writing, perform a coverage cross-check:

1. List all acceptance criteria across all tasks
2. Verify each one appears in at least one scenario row in the plan
3. If any criterion is unmapped, add the missing scenario and note it was added during validation

Report the coverage summary:
```
Test plan written: .bot/workspace/product/test-plan.md

Coverage summary:
- Task groups covered: N
- Total acceptance criteria: N
- Mapped to scenarios: N  ← must equal total
- Integration scenarios: N
- E2E / acceptance scenarios: N
- UAT scenarios: N
- Unmapped criteria fixed during validation: N
```

### Step 6 — Commit (if in autonomous mode)

If running inside an autonomous execution session, commit the test plan file:
```
docs: add project test plan

[task:XXXXXXXX]
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

If running interactively, present the summary and let the operator decide whether to commit.

## Integration Points

| When | How |
|------|-----|
| After full roadmap generation (03b) | Run this workflow before any task moves to `analysing` |
| After a change request (91-new-tasks) | Re-run this workflow to extend the existing plan with new scenarios |
| During task analysis (98-analyse-task) | Reference `.bot/workspace/product/test-plan.md` to extract relevant scenario IDs for the task being analysed — do not regenerate the whole plan |

## Anti-Patterns

- **Do not generate the plan from tasks alone** — missing product context means missing scope items
- **Do not regenerate the plan per task** — one plan covers the project; per-task analysis reads from it
- **Do not skip the prerequisites check** — a plan built on incomplete task definitions will have coverage gaps
- **Do not leave acceptance criteria unmapped** — every criterion must trace to a scenario ID