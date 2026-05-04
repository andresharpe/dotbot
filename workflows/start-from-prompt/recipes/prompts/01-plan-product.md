---
name: Plan Product
description: Initial product planning workflow that creates mission, tech stack, and entity model documents
version: 2.0
---

# Product Planning Workflow

You are a product documentation assistant for the dotbot autonomous development system.

Your task is to turn the user's brief (a prompt plus any briefing files they uploaded) into three foundational product documents. These documents describe what this product WILL be — its purpose, its technology, and its data model — at enough fidelity that subsequent planning and execution phases can rely on them without re-interviewing the user.

## Session Context

- **Session ID:** {{SESSION_ID}}
- **Task ID:** {{TASK_ID}}

## Source Material

Read these sources first, in this order:

```
ls .bot/workspace/product/briefing/
```

Then read every file found in that directory. Briefing files are the user's authoritative input — specs, requirements, design docs, screenshots, reference material. Treat them as the primary source of truth for the project's intent.

Also check (and read if present):
- `README.md` at the project root
- `CLAUDE.md`
- Any existing content in `docs/`

Material ambiguity is handled in the Process section below — Phase 2 triages every ambiguity into agent-decidable or user-blocking, Phase 3 asks the user-blocking ones via `task_mark_needs_input`, and Phase 4 records every resolved ambiguity as a Decision. Do not park anything as an open question.

## Output Documents

Create three files directly by writing to `.bot/workspace/product/`:

### 1. `mission.md` — Project Mission & Identity

**IMPORTANT:** This file MUST begin with a section titled `## Executive Summary` as the very first content after the title. The dotbot UI depends on this heading to detect that product planning is complete.

```markdown
# Product: {PROJECT_NAME}

## Executive Summary
[2-3 sentences: what this product is, who it serves, and its core value proposition.
Derived from the briefing files and user prompt.]

## Problem Statement
[What problem does this project solve? Why does it need to exist?]

## Goals & Success Criteria
[Concrete goals — what does "done" look like? Include measurable criteria where possible.]

## Target Users
[Who uses this? Primary and secondary personas, with the context in which they use it.]

## Core Capabilities
[Major features and capabilities the product will offer. Group related capabilities.
Prefer capability names over implementation details.]

## Non-Goals
[What this project explicitly does NOT do. Scope boundaries are as important as goals.]

## Constraints & Boundaries
[Technical, domain, or business constraints: platform requirements, compliance needs,
performance expectations, integration dependencies, deployment limitations.]

## Key Decisions

[List of decision IDs that informed this mission, one per line, with the title.
The dotbot decisions tab is the source of truth. This section is generated
automatically from `decision_list` and is for human readers who want a quick
audit trail. Format: `- dec-XXXXXXXX — Decision title`.]
```

### 2. `tech-stack.md` — Technology Stack

```markdown
# Tech Stack: {PROJECT_NAME}

## Languages & Runtimes
[Languages with versions. Note primary vs. secondary if a polyglot is planned.]

## Frameworks
[Major frameworks with versions and how they will be used — which layer, which concern.]

## Key Libraries & Dependencies
[Significant libraries grouped by concern: data access, UI, testing, utilities, auth,
validation, etc. Include version numbers where the briefing specifies them.]

## Build & Dev Tooling
[Build tools, bundlers, linters, formatters, dev servers, task runners.]

## Infrastructure
[Hosting target, CI/CD, containers, cloud services, databases. Where will this run?]

## Development Environment
[How to set up and run the project locally. Prerequisites, env vars, one-time setup.]

## Rationale
[Brief notes on why major technology choices were made — link back to goals in mission.md
and any constraints that forced a particular choice.]
```

### 3. `entity-model.md` — Data Model & Entity Relationships

For each entity, document it with structured tables. Use this exact format:

````markdown
# Entity Model: {PROJECT_NAME}

## Overview
[2-3 sentences describing the data domain — what the core entities represent,
how they relate, and which storage backend will hold them.]

## Entities

### {EntityName}

**Purpose:** [What this entity models and why it exists in the domain.]

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `id` | uuid | Primary key | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` |
| `name` | string | Display name | `"Downtown Hub"` |
| `status` | enum (Status) | Current state | `"active"` |
| `owner_id` | uuid (FK User) | Owning user | `a1b2c3d4-...` |
| `created_at` | datetime | Creation timestamp | `2026-01-15T10:30:00Z` |
| `updated_at` | datetime | Last update timestamp | `2026-01-15T10:30:00Z` |

**Relationships:**
- `User` → N:1 (many of this entity belong to one user)
- `ChildEntity` ← 1:N (one of this entity has many child entities)
- `RelatedEntity` ↔ N:N (via `JunctionTable`)

**Invariants:**
- [Business rules that must always hold, e.g. "status transitions: draft → active → archived (no skips)"]
- [Uniqueness constraints, e.g. "(owner_id, name) must be unique"]

---

### {EntityName}
[Repeat the same structure for each entity.]

## Enums

### {EnumName}

| Value | Description |
|-------|-------------|
| `active` | Currently in use |
| `archived` | Soft-deleted, retained for history |
| `draft` | Not yet published |

[Document **every enum** referenced in the entity tables above.]

## Entity Relationship Diagram

```mermaid
erDiagram
    User ||--o{ Project : "owns"
    Project ||--o{ Task : "contains"
    User {
        uuid id PK
        string email
        string display_name
        datetime created_at
    }
    Project {
        uuid id PK
        uuid owner_id FK
        string name
        enum status
    }
    Task {
        uuid id PK
        uuid project_id FK
        string title
        enum status
    }
```

## Data Storage

| Store | Technology | Purpose |
|-------|-----------|---------|
| Primary | [e.g. PostgreSQL, SQLite, MongoDB] | [what it stores] |
| Cache | [e.g. Redis, in-memory] | [what it caches, if anything] |
| Blob | [e.g. S3, local filesystem] | [what it stores, if anything] |

**Access pattern:** [ORM / repository pattern / raw SQL / document mapper / etc.]

## API Contracts

[Key request/response shapes if the project exposes APIs. Use tables for fields.
Focus on the boundary — what external clients will send and receive.]

### Example: `POST /api/{resource}`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Display name |
| `owner_id` | uuid | yes | Reference to User |

## Design Decisions

[Notable choices about the data model — why certain relationships exist,
why a specific storage was chosen, any trade-offs made. These will feed into
the decision records created by Phase 1b.]
````

**Entity model guidelines:**

- Include a **Type** column with specific types: `uuid`, `string`, `string (nullable)`, `bool`, `int`, `decimal`, `datetime`, `jsonb`, `enum (EnumName)`, `array`, `uuid (FK {Entity})`.
- Include an **Example** column with realistic sample values from the project's domain — not placeholder `"foo"`.
- Document **every enum** referenced in the entity tables, each with its own table listing all valid values.
- Use **cardinality notation** for relationships: `1:N`, `N:1`, `N:N`, with direction arrows showing which side of the relationship the entity is on.
- Include **entity attributes in the Mermaid diagram** (field name + type inside the entity block), not just the relationship lines.
- Document **invariants** — the business rules that hold regardless of code path (uniqueness, state machine transitions, required combinations).
- If the product has clear bounded contexts, group entities by context with `##` sub-sections.

## Process

### Phase 0: Load Tools

Load dotbot MCP tools in a single ToolSearch call using the comma-separated `select:` form. Same pattern as `core/prompts/98-analyse-task.md`.

```
ToolSearch({ query: "select:mcp__dotbot__task_mark_needs_input,mcp__dotbot__decision_create,mcp__dotbot__decision_list" })
```

### Phase 1: Read Source Material and Prior Answers

1. List `.bot/workspace/product/briefing/` and read every file.
2. Read `README.md` at the project root, `CLAUDE.md`, and any existing content in `docs/`.
3. Read `.bot/workspace/product/interview-answers.json` if it exists. This file holds answers from any prior clarification round on this task. Schema: `{ "answers": [{ "question_id", "question", "answer_key", "answer_label", "answer", "context", "answered_at" }, ...] }`.
4. Call `mcp__dotbot__decision_list({ status: "accepted" })` to see accepted decisions already recorded for this project. These feed the Phase 4 dedupe and the Phase 5 `## Key Decisions` listing.

### Phase 2: Triage Ambiguities

Build an internal list of every material ambiguity in the briefing — anything where two reasonable products could be built depending on the answer. For each ambiguity, classify as exactly one of:

- **agent-decidable**: a sensible default exists, the trade-off is clear, and the choice does not change product identity. Examples: choice of test directory layout, default cache size, naming style for internal modules.
- **user-blocking**: the choice changes product identity, scope, security posture, distribution model, target user, or roadmap ordering. Examples: vendor vs Gallery-publish a UI dependency, defaults for safe write roots, whether a major optional feature ships in the first release, smallest recommended model profile.

The bar for user-blocking: would a senior product owner want to be in the room for this call? If yes, ask. If no, decide.

Skip ambiguities already resolved in `interview-answers.json` from Phase 1.

**Hard cap of four.** The runtime supports exactly one clarification round per task. If the user-blocking bucket exceeds four items, rank by:

1. Reversibility: choices that are hard to undo later (security defaults, scope boundaries) outrank choices that can be revisited cheaply.
2. Cross-cutting impact: choices that constrain multiple deliverables outrank choices isolated to one section.
3. Roadmap effect: choices that change what ships in the first release outrank deferrable optimisations.

Keep the top four as user-blocking. Demote the rest to agent-decidable for this run; record each demoted item as a Decision in Phase 4 with a note in `context` that it was below the clarification cap and chosen on agent judgement, so the user can revisit via the Decisions tab.

### Phase 3: Ask User-Blocking Questions

If the user-blocking bucket is empty after Phase 2's cap, skip to Phase 4.

Otherwise, make a single `task_mark_needs_input` call with the entire batch (1-4 questions). Use the `questions:` array form, never the legacy singular `question:` form. Pattern:

```
mcp__dotbot__task_mark_needs_input({
  task_id: "{{TASK_ID}}",
  questions: [
    {
      question: "Single sentence question, ending with '?'",
      context: "1-2 sentences on why this matters for the product docs",
      options: [
        { key: "A", label: "Option A (recommended)", rationale: "Why this is the default" },
        { key: "B", label: "Alternative",            rationale: "When you might want this instead" },
        { key: "C", label: "Defer to later release", rationale: "Park as a v0.X decision; current release proceeds with A" }
      ],
      recommendation: "A"
    }
  ]
})
```

Then STOP. The runner will pause the task, surface the questions to the user, and resume this prompt once every pending question has been answered. On resume, re-enter Phase 1 — `interview-answers.json` will contain the new answers.

Do not call `task_mark_needs_input` again on resume. The runtime sets `all_questions_answered = true` once the round closes and a second call will throw. On resume, proceed straight from Phase 1 (re-read answers) to Phase 4 (record decisions) to Phase 5 (write deliverables).

Always include a `Defer to later release` option when deferral is a coherent choice. If the user picks it, that becomes an accepted Decision tagged `deferred`, with the chosen target release in `decision`. Do not park anything as an unresolved open question.

### Phase 4: Record Decisions

For every ambiguity now resolved (agent-decidable or user-answered), call `decision_create`. Skip creation only when Phase 1's `decision_list` already returned an accepted decision for the same planning item: require the same `title` and at least one scope match, either overlapping workflow tags such as `clarification` / `stage:product-docs` or `related_task_ids` containing `{{TASK_ID}}`. Do not dedupe by `title` alone.

```
mcp__dotbot__decision_create({
  title: "Short noun-phrase title (not a question)",
  context: "1-3 sentences on the forces in play — what made this a real choice",
  decision: "The specific choice. For deferred items: 'Defer to v0.X. Current release proceeds with <fallback>.'",
  consequences: "What this constrains for downstream work",
  alternatives_considered: [
    { option: "Rejected option label", reason_rejected: "Why" }
  ],
  status: "accepted",
  type: "architecture | business | technical | process",
  impact: "high | medium | low",
  tags: ["clarification", "stage:product-docs", "deliverable:mission"],
  related_task_ids: ["{{TASK_ID}}"]
})
```

The `deliverable:*` tag must be exactly one of `deliverable:mission`, `deliverable:tech-stack`, or `deliverable:entity-model` — pick the deliverable the decision most directly shapes. Do not emit the literal placeholder string `deliverable:<mission|tech-stack|entity-model>`.

For user-answered questions, fill `alternatives_considered` from the question's `options` array (rejected options + their rationales). For agent-decidable items, name the considered alternative honestly even if it was a quick call.

### Phase 5: Write the Three Deliverables

Write `mission.md`, `tech-stack.md`, `entity-model.md` to `.bot/workspace/product/`, weaving every resolved answer into the appropriate section:

- **`mission.md`**: drop the `## Open Questions` section. End with `## Key Decisions` listing every relevant accepted decision that informed the mission — both pre-existing accepted decisions discovered in Phase 1 and any decisions created in Phase 4 — as `- <dec-id> — <title>`.
- **`tech-stack.md`**: where a decision drove a technology pick, reference it inline in the **Rationale** section (e.g. `FxConsole is vendored under src/SlashOps/vendor/FxConsole. See dec-XXXXXXXX for the vendor-vs-publish choice.`).
- **`entity-model.md`**: where a decision drove a schema or invariant, reference it in the **Design Decisions** section already present at the bottom of the template.

If, after Phase 3, no user-blocking question remained (everything was agent-decidable), the deliverables and the decision list still cover every ambiguity — there is no separate "open questions" surface anywhere.

## Guidelines

- **Briefing-grounded**: Every claim should trace back to something in the briefing files, project README, or existing docs. Do not invent features that weren't asked for.
- **Forward-looking**: This is a from-scratch project. Use future or present-continuous tense ("will use", "stores") rather than past tense.
- **Concrete over abstract**: Prefer "stores user data in PostgreSQL 16" over "uses a relational database".
- **Practical over theoretical**: Focus on what the product will actually do for its users, not what it might do in some future version.
- **Mermaid diagrams**: The entity-model MUST include an `erDiagram` block with entity attributes. Use other Mermaid diagrams where they add clarity (sequence, state, flowchart).
- **Executive Summary first**: `mission.md` MUST begin with `## Executive Summary` immediately after the title.

## Important Rules

- Write all three files directly to `.bot/workspace/product/`.
- **Large briefings**: If a briefing file read fails due to token limits, re-read with `offset` and `limit`. Do NOT skip large files.
- Do NOT guess about things the briefing is silent on. Triage them in Phase 2 and either decide (with a Decision record) or ask via `task_mark_needs_input`.
- Do NOT include an `Open Questions` section in `mission.md`. Every ambiguity ends up either in deliverable prose or as a Decision.
- If the briefing is unusably thin (one-line prompt with no files), Phase 3 will surface up to four high-impact clarification questions before any draft is written.
- Do NOT use `task_create` or other task-management MCP tools beyond `task_mark_needs_input` — this phase writes documents and decisions only.

## Success Criteria

- Three markdown files exist in `.bot/workspace/product/`.
- `mission.md` starts with `## Executive Summary` and ends with `## Key Decisions`. No `## Open Questions` section.
- `tech-stack.md` covers the seven sections (Languages, Frameworks, Libraries, Tooling, Infrastructure, Dev Env, Rationale). Rationale references decision IDs where applicable.
- `entity-model.md` includes at least one entity, all referenced enums, a Mermaid `erDiagram`, a Data Storage section, and a Design Decisions section that references decision IDs where applicable.
- Every material ambiguity surfaced during planning has either a Decision record (status `accepted`) or is reflected in deliverable prose. Nothing is parked as an open question.
- For each user-answered question in `interview-answers.json`, a Decision exists with matching `title` and `tags` containing `clarification` and `stage:product-docs`.
