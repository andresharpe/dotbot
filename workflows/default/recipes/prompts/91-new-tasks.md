<!-- Used by 'task-creation' process type only. NOT used during kickstart. -->
---
name: New Tasks
description: Create change requests and generate tasks
version: 2.2
---

# New Tasks Workflow

Capture requirements as a change request, then create tasks via `task_create_bulk`.

**Use for:** New features, enhancements, bug fixes, tech debt, refactoring.

**Flow:** User Input → Change Request → Break Down → Create Tasks via MCP

## Agent Teams Strategy

For complex change requests (estimated L/XL effort or touching 5+ files), use a team-based approach:

### Team Composition

1. **Lead** — Owns the change request, coordinates breakdown, makes final decisions on task structure.
2. **Investigator** — Explores the codebase for impact analysis: finds existing patterns, identifies affected files, checks for related code and potential conflicts.
3. **Task Designer** — Drafts the task breakdown with acceptance criteria, effort estimates, and dependency mapping based on the Lead's requirements and Investigator's findings.

### Team Workflow

1. **Lead** receives the change request and creates a brief: scope, constraints, expected outcome.
2. **Investigator** explores the codebase and reports: affected files, existing patterns to follow, potential risks, related existing tasks.
3. **Task Designer** drafts the task breakdown using the Investigator's findings.
4. **Lead** reviews, adjusts, and creates the final task set via `task_create_bulk`.

### Fallback

For simpler changes (XS-M effort), skip the team approach and execute all steps in a single session.

## Step 1: Gather Requirements

Ask: What do you want to add/change? Why? Any constraints? Expected outcome?

Wait for input. Ask clarifying questions one at a time if needed:
- **Features:** Functionality, UX, edge cases, success criteria
- **Enhancements:** Current state, limitation, desired improvement
- **Fixes:** Current vs expected behavior, reproducibility
- **Infrastructure:** Problem solved, affected components, success criteria

## Step 2: Create Change Request

Save to: `.bot/workspace/product/change-request-{yyyyMMdd_HHmmss}-{slug}.md`

```markdown
# Change Request: {Title}
**Created:** {DateTime}  **Status:** Planning  **Type:** feature|enhancement|fix|infrastructure

## Summary
{What this accomplishes}

## Background
{Why needed}

## Requirements
- Functional: {list}
- Non-functional: {constraints}

## Acceptance Criteria
- [ ] {Testable criteria}

## Technical Considerations
{Affected components, dependencies, integration points}

## Out of Scope
{Exclusions}
```

## Step 3: Load Context

Read product docs from `.bot/workspace/product/`:
- `mission.md` — Core principles and goals
- `tech-stack.md` — Technology stack and libraries
- `entity-model.md` — Data model and relationships
- `prd.md` — Full specification (if exists)

## Step 4: Break Down Into Tasks

Each task should be 1-4 hours, independently testable, single context window.

**Effort:** XS (<1h), S (1-2h), M (2-4h), L (4-8h), XL (8h+, MUST be split into smaller tasks)

**Categories:** `infrastructure`, `core`, `feature`, `enhancement`, `bugfix`, `ui-ux`

### Dependencies

**CRITICAL:** Use ONLY existing task names/IDs/slugs. Validated at creation — invalid deps cause errors.

Before adding dependencies, call `task_list` to retrieve current task IDs. Only reference IDs that exist.

If dependency missing: (1) Create it first in batch, (2) Omit and run parallel, or (3) Two-phase creation.

**Best:** Minimize deps. Most tasks run independently.

## Step 5: Present & Confirm

Show proposed tasks with effort estimates and dependencies. Wait for user confirmation (Yes/Review/Adjust).

## Step 6: Create Tasks

**With dependencies?** Verify with `task_list` first.

```javascript
mcp__dotbot__task_create_bulk({
  tasks: [{
    name: "{Action-oriented title}",
    description: "{What, where, why, how}",
    category: "{category}",
    effort: "{XS|S|M|L|XL}",
    acceptance_criteria: ["{criteria}"],
    steps: ["{steps}"],
    dependencies: [],  // Existing task names/IDs/slugs only
    applicable_agents: ["{path}"],
    applicable_standards: ["{path}"],
    human_hours: 8,   // Optional: estimated hours without AI
    ai_hours: 1       // Optional: estimated hours with AI
  }]
})
```

**Batch deps:** Order correctly — dependency first, dependent second.

Use `task_list` to find current max priority. Assign after existing or interleave by urgency.

## Step 7: Finalize

1. Update change request: `**Status:** Tasks Created` with task IDs
2. Report to user: change request path, task count, IDs, total effort
3. Suggest `task_get_next` to begin work

## Step 8: Plans (Optional)

Offer for L/XL or complex tasks. Use `mcp__dotbot__plan_create`. See `.bot/workspace/tasks/samples/sample-plan-retrospective.md`.

---

## dotbot MCP Tools

| Tool | Purpose |
|------|---------|
| `mcp__dotbot__task_create_bulk` | Create multiple tasks at once |
| `mcp__dotbot__task_list` | List existing tasks (use to verify IDs for dependencies) |
| `mcp__dotbot__plan_create` | Create implementation plan for a task |

---

## Task Schema

| Field | Req | Description |
|-------|-----|-------------|
| `name` | Y | Action-oriented title |
| `description` | Y | What, where, why, how |
| `category` | Y | infrastructure/core/feature/enhancement/bugfix/ui-ux |
| `effort` | Y | XS/S/M/L/XL |
| `acceptance_criteria` | Y | Testable conditions |
| `priority` | N | 1-100 (auto-assigned if omitted) |
| `steps` | N | Implementation guidance |
| `dependencies` | N | Array of task names/IDs/slugs from EXISTING tasks. Validated at creation. |
| `applicable_agents` | N | Agent persona paths |
| `applicable_standards` | N | Standards paths |
| `human_hours` | N | Estimated hours for a skilled developer (no AI) |
| `ai_hours` | N | Estimated hours with AI-assisted development |

**Auto-managed:** `id`, `status`, `created_at`, `updated_at`, `plan_path`

---

## Error Handling

If MCP fails: report error, allow retry. Change request serves as recovery point.
