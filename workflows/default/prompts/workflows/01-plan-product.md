---
name: Plan Product
description: Initial product planning workflow that creates mission, tech stack, and entity model documents
version: 1.1
---

# Product Planning Workflow

This workflow guides you through creating the foundational product documents that define your project.

## Goal
Create three essential product documents:
1. **mission.md** - What the product is, core principles, and goals
2. **tech-stack.md** - Technologies, versions, and infrastructure decisions
3. **entity-model.md** - Data model, entities, and relationships

## Process

### Step 1: Read Briefing Files

Check the `.bot/workspace/product/briefing/` directory for any files the user has uploaded as context. Read all files found there — these may include specs, requirements, design docs, screenshots, or other reference material.

### Step 2: Understand the Project

Review any existing project documentation:
- Check `docs/` for build specifications, requirements, or design documents
- Review the README.md
- Cross-reference with any briefing files from Step 1

If documentation is sparse and this is an interactive session, ask the user about the project.

### Step 3: Extract Mission & Principles
Create `.bot/workspace/product/mission.md` with:

**IMPORTANT:** The file MUST begin with `## Executive Summary` as the first section after the title. The UI depends on this heading to detect that product planning is complete.

- **Executive Summary**: 2-3 sentence overview of what this product is and why it exists
- **Core principles**: The key values and constraints that guide development (e.g., "security first", "simple over complex", "privacy-preserving")
- **Primary goals**: What success looks like (e.g., "automate email triage", "reduce response time by 50%")
- **Target audience**: Who uses this and why

Keep this concise - it's a reference document, not marketing copy.

### Step 4: Document Tech Stack
Create `.bot/workspace/product/tech-stack.md` with:
- **Runtime**: Language, framework, version (e.g., ".NET 10 with ASP.NET Core")
- **Database**: Type and version (e.g., "SQLite 3.x embedded")
- **Key libraries**: Major dependencies with purpose (e.g., "Wolverine for CQRS", "Telegram.Bot for UI")
- **External APIs**: Third-party services used (e.g., "Microsoft Graph for email/calendar")
- **Infrastructure**: Hosting, deployment, networking setup
- **Development tools**: Testing frameworks, build tools

Format as a simple list or table - prioritize readability.

### Step 5: Define Entity Model
Create `.bot/workspace/product/entity-model.md` with:
- **Core entities**: Main domain objects (e.g., User, Email, Sender, Rule)
- **Relationships**: How entities connect (e.g., "Email belongs to Sender", "Rule matches Email")
- **Key fields**: Important properties per entity (don't list every field, just the critical ones)
- **Data flow**: How data moves through the system (optional but helpful for complex systems)
- **Entity Relationship Diagram**: Include a Mermaid.js `erDiagram` block showing entities, their key fields, and relationships. This provides a visual overview alongside the text descriptions.

Use simple text descriptions for the prose sections — avoid full SQL schemas or code. This is conceptual. The Mermaid diagram should complement the text, not replace it.

## Clarifying Questions

When running interactively, ask clarifying questions if needed:

```
When mission is unclear:
- What problem does this solve?
- Who benefits from this?
- What makes this different from alternatives?
- What are the non-negotiable principles?

When tech stack is unclear:
- What's the target runtime environment?
- Are there existing infrastructure constraints?
- What are the performance requirements?
- Are there security/compliance requirements?

When entity model is unclear:
- What are the main "things" this system manages?
- How do these things relate to each other?
- What data needs to persist vs. what's ephemeral?
- Are there external systems providing data?
```

When running autonomously (e.g., from the kickstart endpoint), make reasonable inferences and skip questions.

## Output Location
All files go in `.bot/workspace/product/`:
- `.bot/workspace/product/mission.md`
- `.bot/workspace/product/tech-stack.md`
- `.bot/workspace/product/entity-model.md`

## Success Criteria
- Three markdown files created
- Each file is concise and focused (not a novel)
- Content is project-specific (not generic templates)
- Technical decisions are captured with rationale
- mission.md starts with an `## Executive Summary` section
