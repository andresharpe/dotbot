---
name: Plan Task Groups
description: Phase 2a — identify high-level implementation groups from product documents
version: 1.1
---

# Task Group Planning

You are a roadmap planning assistant. Your job is to read the product documents and identify 5-10 natural implementation groups, then write a `task-groups.json` manifest.

## Phase 0: Load Required Tools

**Built-in tools** (`WebSearch`, `WebFetch`, `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`) are always available — never use ToolSearch for them.

**Load dotbot tools** (all in parallel, a single batch):

```
ToolSearch({ query: "select:mcp__dotbot__decision_list" })
```

Issue all ToolSearch calls above in a **single parallel batch**. Do not call ToolSearch again after Phase 0. If you see any `mcp__dotbot__*` tool listed as deferred in your initial tool list, that is expected — ToolSearch loads the schema on demand. Do NOT refuse on the grounds that these tools are "missing".

---

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
- **Effort-based buckets** (e.g. "Quick Wins", "Tech Debt", "Stretch Goals") — group by *functional area*, not by size or priority.
- **Groups whose scope cannot yield per-task acceptance criteria** — if you can't state what "done" looks like for each scope item, the group is too vague to expand.
- **Kitchen-sink groups** that bundle multiple unrelated functional concerns under one name (e.g. "Terminal UI, Preflight, Initialize, and Distribution"). Each `name` should describe one coherent concern; if you find yourself joining domains with "and", split.

Each group's acceptance criteria should describe a **deployable increment** — something you could demo or ship independently.

### Step 2.5: Validate Expansion Fan-Out

Group sizing is your responsibility, not 03b's. 03b expands each group at the per-task quality bar (one logical, context-friendly, executable, testable unit per task) and produces as many tasks as that bar demands. If a group's scope would naturally yield 12 or more well-sized tasks at expansion time, the group is too broad — **split it now**, before writing `task-groups.json`.

For each draft group, mentally walk its `scope` items and ask: *"How many distinct logical units of work does this scope require, given the per-task quality bar?"* Use the typical-task heuristic below.

| Scope shape | Likely per-task expansion |
|-------------|--------------------------|
| One small entity (CRUD + tests) | 2-4 tasks |
| One feature with handlers, validation, persistence, tests | 4-7 tasks |
| One subsystem touching 2-3 layers | 6-10 tasks |
| Multiple subsystems bundled | 12+ tasks → **split** |

Healthy groups land in the **3-10 task** range. Set `estimated_task_count` to your honest estimate per group. If your estimate is 12+, you have one of two problems:

- The group bundles unrelated concerns — split into two or more functionally focused groups.
- A single scope item is itself a subsystem — promote it to its own group.

Splitting at this stage is cheap (you are still writing JSON); splitting after 03b has produced 20 questionable tasks is expensive. **Do the work here.**

### Step 3: Define Group Dependencies

Groups should have explicit dependencies via `depends_on`, following the standard dependency chain:

- **Infrastructure** groups have no dependencies.
- **Core entities / data layer** groups depend on infrastructure (DB, config, project scaffolding).
- **Feature handlers** (command/query/API) depend on the core entities they operate on.
- **Background jobs and workers** depend on the feature handlers they orchestrate.
- **UI and final integration** groups depend on the features they surface.

Priority ranges (Step 4) already encode execution order within the chain — use `depends_on` for hard technical dependencies only, not for ordering preference.

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
      "category_hint": "infrastructure",
      "applicable_decisions": ["dec-abc12345", "dec-def67890"]
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
| `estimated_task_count` | Yes | Realistic estimate of how many tasks 03b will produce when expanding this group at the per-task quality bar (one logical / context-friendly / executable / testable unit each). Healthy range is **3-10**. If your estimate is 12+, the group is too broad — split it (Step 2.5) before writing this file. |
| `depends_on` | Yes | Array of group IDs this depends on (empty for root groups) |
| `priority_range` | Yes | `[min, max]` — priority range for tasks in this group |
| `category_hint` | Yes | Default category for tasks in this group. Must be one of the six valid `category` enum values (see [Task Schema Reference](#task-schema-reference-inherited-by-phase-2b) below): `infrastructure`, `core`, `feature`, `enhancement`, `ui-ux`, or `bugfix`. Use `ui-ux` for all user-facing / frontend work. **Do NOT invent new categories** like `frontend`, `backend`, or `api` — the MCP `task_create_bulk` validator will reject them. |
| `applicable_decisions` | Yes | Array of accepted-decision IDs (`dec-XXXXXXXX`) that materially constrain this group's implementation. The 03b expansion runtime substitutes this list into `{{GROUP_APPLICABLE_DECISIONS}}` and the prompt reads each via `decision_get`. Use `[]` only when no accepted decisions touch this group's domain — an empty list forces 03b's `decision_list` fallback. Pull candidates from the `decision_list` call you made in Step 1 and include any whose `consequences` reference this group's name, scope items, or category. |

---

## Task Schema Reference (inherited by Phase 2b)

The per-group expansion prompt (`03b-expand-task-group.md`) will produce individual tasks from each group's `scope` bullets. You are planning at the group level, but every group you define must be *expandable* into tasks that carry the following schema. Keep this in mind when sizing, scoping, and estimating groups:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Brief, action-oriented title ("Implement X command handler", "Add X entity with migrations") |
| `description` | Yes | What / where / why / how / patterns to reference |
| `category` | Yes | `infrastructure` / `core` / `feature` / `enhancement` / `ui-ux` / `bugfix` |
| `priority` | Yes | 1–100 (within this group's `priority_range`) |
| `effort` | Yes | `XS` / `S` / `M` / `L` / `XL` (see sizing table below) |
| `acceptance_criteria` | Yes | Array of specific, testable success conditions — see quality bar below |
| `steps` | No | Implementation steps for guidance |
| `dependencies` | No | Array of task IDs *or* task names/slugs this depends on (within or across groups). `task_create_bulk` accepts both forms; 03b's intra-batch references use names, cross-batch typically use IDs once known. |
| `applicable_standards` | No | Standards files to read before implementing |
| `applicable_agents` | No | Agent files to use for implementation |
| `applicable_decisions` | No | Decisions constraining this task (narrowed from the group's list) |
| `human_hours` | Yes | Estimated developer-hours for a skilled human, unassisted |
| `ai_hours` | Yes | Estimated AI-assisted developer-hours |

Groups whose `scope` items cannot produce tasks matching this schema are too vague — refine them before writing `task-groups.json`.

## Good Task Acceptance Criteria

When 03b expands your groups, each task's `acceptance_criteria` must meet this bar:

- **Specific and testable** — not "works correctly" but "returns 200 with JSON body containing `{id, name}` on success".
- **Each item starts with a verb** — "Returns…", "Rejects…", "Persists…", "Logs…".
- **Covers the happy path and key edge cases** — invalid input, missing auth, empty result set, concurrent mutation, etc.
- **Includes test requirements where appropriate** — "Unit test asserts…", "Integration test verifies…".
- **No "TODO" or open ends** — if you don't know what done looks like, the task is not ready to create.

When drafting a group's `acceptance_criteria`, make sure each bullet describes a *shippable behavior* of the whole group — not a developer task. If you can't phrase it as a verifiable behavior, split or rescope the group.

## Effort Sizing

Use this table for task-level `effort` values (which feed into the group's `effort_days`):

| Effort | Typical Duration (human) | Examples |
|--------|--------------------------|----------|
| `XS`   | < 1 hour   | Add one field to an entity, flip a config, register a handler |
| `S`    | 1–2 hours  | Simple command/query handler, basic CRUD endpoint |
| `M`    | 2–4 hours  | Feature with tests, integration wiring, small migration |
| `L`    | 4–8 hours  | Complex feature, multiple components, end-to-end wiring |
| `XL`   | 1–2 days   | Major subsystem, significant refactoring, cross-cutting change |

A group's `effort_days` should roughly equal the sum of its tasks' human-hour estimates divided by 6 (focused dev-hours per day). If a group exceeds ~15 `effort_days`, split it.

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

---

**What happens next.** The per-group expansion in `03b-expand-task-group.md` inherits the **Task Schema Reference**, **Good Task Acceptance Criteria**, and **Effort Sizing** sections above. Every constraint stated here must carry through to the tasks 03b produces — do not relax them during expansion. Groups that are under-specified now will produce thin tasks later.
