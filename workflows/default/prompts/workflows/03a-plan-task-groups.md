---
name: Plan Task Groups
description: Phase 2a — identify high-level implementation groups from product documents
version: 1.1
---

# Task Group Planning

You are a roadmap planning assistant. Your job is to read the product documents and identify 5-10 natural implementation groups, then write a `task-groups.json` manifest.

## Goal

Produce a lightweight grouping of work that can later be expanded into detailed tasks. Each group represents a coherent slice of functionality that can be planned in isolation. **Focus on what's needed to ship a working product.**

## Instructions

### Step 1: Read All Product Documents

Read every file in `.bot/workspace/product/`:
- `mission.md` — Core principles, goals, target audience
- `tech-stack.md` — Technology choices and libraries
- `entity-model.md` — Data model and entity relationships
- Any other `.md` files present (PRD, change requests, etc.)

Also read accepted decisions — these constrain valid implementation approaches:
```javascript
mcp__dotbot__decision_list({ status: "accepted" })
```
Note each decision's ID, title, and consequences. When assigning `applicable_decisions` to groups in Step 5, include decisions whose consequences directly affect that group's implementation choices.

### Step 2: Identify Implementation Groups

Based on the product docs, identify **5-10 natural implementation groups**. Think in terms of deployable increments — each group should bring the product closer to a working state.

Examples of good groups:
1. **Foundation & Infrastructure** — Project setup, database, config, basic hosting
2. **Core Entities & Data Layer** — Entity definitions, repositories, migrations
3. **Authentication & Authorization** — Auth providers, identity, permissions
4. **Primary Business Logic** — Command/query handlers, service layer, API endpoints
5. **Background Processing** — Scheduled jobs, event handlers, queues
6. **Notifications & Communication** — Email, push, in-app notifications
7. **User-Facing Interface** — UI screens, views, client-side logic

Not all projects need all of these. Adapt to the actual project scope. Merge small groups, split large ones.

**Do NOT create groups for:**
- Generic "Polish & Testing" — testing is part of every group's acceptance criteria
- Vague "Enhancements" or "Nice-to-haves" — each group should deliver concrete functionality
- "Intelligence & Rules" unless the product specifically requires AI/ML features
- Anything that doesn't contribute to a shippable product

Each group's acceptance criteria should describe a **deployable increment** — something you could demo or ship independently.

### Step 3: Define Group Dependencies

Groups should have explicit dependencies via `depends_on`:
- Infrastructure groups have no dependencies
- Entity/data groups depend on infrastructure
- Feature groups depend on the entities they use
- Background jobs depend on the features they orchestrate

### Step 3b: Estimate Effort Days

Assign `effort_days` to each group — the estimated number of developer-days for a skilled human to complete the group (not AI-assisted time).

| Complexity | Effort Days | Examples |
|------------|-------------|----------|
| Simple | 1-2 | Config setup, simple CRUD entity |
| Standard | 3-5 | Auth integration, standard feature with tests |
| Complex | 5-10 | Multi-entity business logic, complex integrations |
| Major | 10-15 | Large subsystems, multiple integration points |

### Step 4: Assign Priority Ranges

Each group gets a non-overlapping priority range that encodes execution order:

| Order | Priority Range | Typical Groups |
|-------|---------------|----------------|
| 1     | 1-10          | Foundation, infrastructure |
| 2     | 11-20         | Core entities, data layer |
| 3     | 21-35         | Auth, external integrations |
| 4     | 36-55         | Primary business logic |
| 5     | 56-70         | Background processing |
| 6     | 71-85         | Communication, notifications |
| 7     | 86-100        | UI, final integration |

### Step 5: Write task-groups.json

Write the file directly to `.bot/workspace/product/task-groups.json`.

**Do NOT use MCP tools to create tasks.** Just write the JSON file.

The file format:

```json
{
  "generated_at": "2026-01-01T00:00:00Z",
  "project_name": "Project Name from mission.md",
  "total_groups": 7,
  "groups": [
    {
      "id": "grp-1",
      "name": "Foundation & Infrastructure",
      "order": 1,
      "description": "Project structure, database schema, configuration loading, basic API host setup",
      "effort_days": 3,
      "scope": [
        "Solution and project structure setup",
        "Database schema and migrations",
        "Configuration loading and validation",
        "Basic API host with health check"
      ],
      "acceptance_criteria": [
        "Solution builds successfully",
        "Database connection works",
        "API responds to health check"
      ],
      "estimated_task_count": 4,
      "depends_on": [],
      "priority_range": [1, 10],
      "category_hint": "infrastructure"
    }
  ]
}
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique group ID: `grp-1`, `grp-2`, etc. |
| `name` | Yes | Human-readable group name |
| `order` | Yes | Execution order (1 = first) |
| `description` | Yes | 1-2 sentence summary of what this group covers |
| `effort_days` | Yes | Estimated developer-days to complete this group (1-20) |
| `scope` | Yes | Array of specific items to implement (these become task seeds) |
| `acceptance_criteria` | Yes | Group-level success conditions |
| `estimated_task_count` | Yes | Expected number of tasks (2-8 per group) |
| `depends_on` | Yes | Array of group IDs this depends on (empty for root groups) |
| `priority_range` | Yes | `[min, max]` — priority range for tasks in this group |
| `category_hint` | Yes | Default category for tasks: infrastructure, core, feature, enhancement |

### Guidelines

- **Keep it lightweight.** Scope bullets, not detailed task breakdowns.
- **5-10 groups** is the sweet spot. Fewer than 5 means groups are too large; more than 10 means too granular.
- **Each scope item** should map to roughly 1-2 tasks when expanded later.
- **Estimated task count** should total 20-60 across all groups.
- **Total effort_days** typically 15-60 across all groups. Reflect real developer time, not AI-assisted.
- **Category hints** guide task categorization but individual tasks may override.
- **Priority ranges** must not overlap between groups.

## Error Handling

- If product docs are missing or incomplete, work with what's available
- If the project scope is very small (< 15 tasks total), use 3-5 groups
- If the project scope is very large (> 60 tasks), use 8-10 groups

## Output

Write `.bot/workspace/product/task-groups.json` and confirm with a brief summary:
- Number of groups created
- Total estimated tasks
- Total estimated effort (days)
- Group names and their order
