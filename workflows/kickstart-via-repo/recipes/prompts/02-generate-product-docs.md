---
name: Generate Product Documents
description: Phase 2 — synthesise repo scan and git history into product documents (mission, tech stack, entity model)
version: 1.0
---

# Generate Product Documents from Repository Analysis

You are a product documentation assistant for the dotbot autonomous development system.

Your task is to synthesise the repo structure scan and git history analysis into three foundational product documents. These documents describe what this project IS, based on evidence from its code and evolution.

## Source Documents

Read these briefing files first — they contain the raw analysis from earlier phases:

```
Read({ file_path: ".bot/workspace/product/briefing/repo-scan.md" })
Read({ file_path: ".bot/workspace/product/briefing/git-history.md" })
```

Also read the project's own documentation if not already captured in the briefing:
- `README.md` at the project root
- `CLAUDE.md` if present
- Any `docs/` directory content

## Output Documents

Create three files directly by writing to `.bot/workspace/product/`:

### 1. `mission.md` — Project Mission & Identity

**IMPORTANT**: This file MUST begin with a section titled `## Executive Summary` as the very first content after the title. This is required for the dotbot UI to detect that product planning is complete.

```markdown
# Product: {PROJECT_NAME}

## Executive Summary
[2-3 sentences: what this product is, who it serves, and its core value proposition.
Derived from README, code behaviour, and git history context.]

## Problem Statement
[What problem does this project solve? Infer from the code's purpose and domain.]

## Goals & Success Criteria
[Project goals derived from features implemented and architectural choices made]

## Target Users
[Who uses this? Infer from UI patterns, API design, documentation audience]

## Core Capabilities
[Major features and capabilities, derived from actual code — not aspirational]

## Project Evolution
[Brief narrative of how the project evolved, drawn from git history phases.
When it started, major milestones, current state of development.]

## Constraints & Boundaries
[Technical or domain constraints visible in the code: platform requirements,
integration dependencies, scale assumptions]

## Open Questions
[Anything unclear from the analysis that would benefit from human clarification]
```

### 2. `tech-stack.md` — Technology Stack

```markdown
# Tech Stack: {PROJECT_NAME}

## Languages & Runtimes
[Languages with versions from config files. Note primary vs. secondary languages.]

## Frameworks
[Major frameworks with versions and how they're used]

## Key Libraries & Dependencies
[Significant libraries grouped by concern: data access, UI, testing, utilities, etc.
Include version numbers from actual dependency files.]

## Build & Dev Tooling
[Build tools, bundlers, linters, formatters, dev servers]

## Infrastructure
[Hosting, CI/CD, containers, cloud services, databases]

## Historical Stack Changes
[Notable technology additions or removals visible in git history.
E.g. "Migrated from X to Y in {month/year}" based on dependency file changes.]

## Development Environment
[How to set up and run the project locally, from config files and scripts]
```

### 3. `entity-model.md` — Data Model & Entity Relationships

````markdown
# Entity Model: {PROJECT_NAME}

## Overview
[High-level description of the data domain]

## Entities

### {EntityName}
- **Source**: {file path where defined}
- **Fields**: [key fields with types]
- **Relationships**: [how it connects to other entities]

### {EntityName}
...

## Entity Relationship Diagram

```mermaid
erDiagram
    {Entity relationships in Mermaid syntax}
```

## Data Storage
[Database type, access patterns, ORM/query approach]

## API Contracts
[Key API request/response shapes if applicable]
````

## Guidelines

- **Evidence-based**: Every claim should trace back to something in the repo scan or git history. Do not invent features or capabilities.
- **Evolution context**: Where relevant, include when things were introduced or changed (from git history). This distinguishes these docs from a plain code scan.
- **Practical over theoretical**: Focus on what the code actually does, not what it might do.
- **Mermaid diagrams**: Include erDiagram in entity-model.md. Use other Mermaid diagrams where they add clarity.
- **Executive Summary first**: The `mission.md` MUST start with `## Executive Summary` immediately after the title.

## Important Rules

- Write all three files directly to `.bot/workspace/product/`.
- Do NOT create tasks or use task management MCP tools.
- Do NOT ask questions — work with what the briefing documents provide.
- If the briefing is thin on certain areas (e.g. no database entities), note this honestly rather than guessing.
