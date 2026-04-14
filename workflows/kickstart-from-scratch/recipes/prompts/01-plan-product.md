---
name: Plan Product
description: Initial product planning workflow that creates mission, tech stack, and entity model documents
version: 2.0
---

# Product Planning Workflow

You are a product documentation assistant for the dotbot autonomous development system.

Your task is to turn the user's brief (a prompt plus any briefing files they uploaded) into three foundational product documents. These documents describe what this product WILL be — its purpose, its technology, and its data model — at enough fidelity that subsequent planning and execution phases can rely on them without re-interviewing the user.

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

If running autonomously (no interactive channel), make reasonable inferences from the briefing and proceed. If ambiguity would materially change the product docs, record it in the **Open Questions** section rather than guessing silently.

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

## Open Questions
[Anything unclear in the briefing that the user should clarify before execution phases.
Leave this section empty if everything is clear.]
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

### Step 1: Read Briefing & Source Material

Walk the `.bot/workspace/product/briefing/` directory, the project README, and any `docs/` content as described in **Source Material** above. Build a mental model of what the user wants to build before writing anything.

### Step 2: Draft Mission

Synthesise the briefing into `mission.md` using the template above. Keep it concise — this is a reference document, not marketing copy. The **Executive Summary** must be the first heading.

### Step 3: Draft Tech Stack

From the briefing, identify the runtime, frameworks, libraries, infrastructure, and tooling. Write `tech-stack.md` using the template above. If the briefing says "use X", capture it. If the briefing is silent on a category, record that in the **Rationale** section and flag it in `mission.md`'s **Open Questions**.

### Step 4: Draft Entity Model

Identify the core entities the product will manage. For each entity:

1. Define its purpose.
2. List its fields in the table format with type, description, and example.
3. Identify its relationships with cardinality.
4. Capture invariants.

Document all enums. Build the Mermaid erDiagram with entity attributes. Describe the storage layer. Sketch the key API contracts.

### Step 5: Clarifying Questions (Interactive Only)

When running interactively and the briefing leaves material ambiguity, ask focused clarifying questions. Never ask more than 3 at a time. Examples:

```
Mission:
- What problem does this solve that existing solutions don't?
- Who is the primary user vs. secondary user?
- What does "success" look like 6 months after launch?

Tech Stack:
- What's the target runtime environment (cloud, on-prem, desktop, mobile)?
- Are there existing infrastructure constraints to inherit?
- What are the performance and scale expectations?
- Are there security or compliance requirements?

Entity Model:
- What are the main "things" this system manages?
- How do these things relate to each other?
- What state does each entity move through over its lifetime?
- What data needs to persist vs. what's ephemeral?
- Are there external systems providing authoritative data for any entity?
```

When running autonomously (e.g., from the kickstart endpoint), make reasonable inferences from the briefing and record unresolved ambiguity in `mission.md`'s **Open Questions** rather than pausing.

## Guidelines

- **Briefing-grounded**: Every claim should trace back to something in the briefing files, project README, or existing docs. Do not invent features that weren't asked for.
- **Forward-looking**: This is a from-scratch project. Use future or present-continuous tense ("will use", "stores") rather than past tense.
- **Concrete over abstract**: Prefer "stores user data in PostgreSQL 16" over "uses a relational database".
- **Practical over theoretical**: Focus on what the product will actually do for its users, not what it might do in some future version.
- **Mermaid diagrams**: The entity-model MUST include an `erDiagram` block with entity attributes. Use other Mermaid diagrams where they add clarity (sequence, state, flowchart).
- **Executive Summary first**: `mission.md` MUST begin with `## Executive Summary` immediately after the title.

## Important Rules

- Write all three files directly to `.bot/workspace/product/`.
- **Large briefings**: If a briefing file read fails due to token limits, re-read with `offset` and `limit` parameters. Do NOT skip large files — they typically contain the most important context.
- Do NOT create tasks or use task management MCP tools — this phase writes documents only.
- Do NOT guess about things the briefing is silent on. Record them as **Open Questions** in `mission.md`.
- If the briefing is unusably thin (e.g. a one-line prompt with no files), note this explicitly in `mission.md` and flag the ambiguity rather than fabricating a product.

## Success Criteria

- Three markdown files exist in `.bot/workspace/product/`.
- `mission.md` starts with `## Executive Summary`.
- `tech-stack.md` covers all seven sections (Languages, Frameworks, Libraries, Tooling, Infrastructure, Dev Env, Rationale).
- `entity-model.md` includes:
  - At least one entity documented with the full field table.
  - Every referenced enum has its own value table.
  - A Mermaid `erDiagram` block with entity attributes (not just relationship lines).
  - A Data Storage section.
- Content is project-specific — no generic template placeholders left behind.
- Technical and structural decisions are captured with rationale for Phase 1b to consume.
