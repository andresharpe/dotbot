---
name: Generate Product Document
description: Create a single product.md capturing the project vision, goals, and approach
version: 1.0
---

# Product Document Workflow

This workflow guides you through creating a single, comprehensive product document that captures the essence of the project.

## Goal

Create one product document:
- **product.md** — A unified document covering what the product is, who it's for, what problem it solves, and the high-level approach.

## Process

### Step 1: Read Briefing Files

Check the `.bot/workspace/product/briefing/` directory for any files the user has uploaded as context. Read all files found there — these may include specs, requirements, design docs, screenshots, or other reference material.

### Step 2: Understand the Project

Review any existing project documentation:
- Check `docs/` for build specifications, requirements, or design documents
- Review the README.md
- Cross-reference with any briefing files from Step 1

If documentation is sparse and this is an interactive session, ask the user about the project.

### Step 3: Create `product.md`

Write `.bot/workspace/product/product.md` with the following structure:

**IMPORTANT:** The file MUST begin with `## Executive Summary` as the first section after the title. The UI depends on this heading to detect that product planning is complete.

```markdown
# Product: {PROJECT_NAME}

## Executive Summary

2-3 sentence overview of what this product is and why it exists. This should be clear enough that someone unfamiliar with the project can understand its purpose.

## Problem Statement

- What problem does this solve?
- Why does this problem matter?
- What happens if it's not solved?

## Goals & Success Criteria

- Primary goals: what success looks like
- Measurable outcomes where possible
- Non-goals: what this project explicitly does NOT aim to do

## Target Users

- Who uses this and why?
- What are their key needs?
- How do they currently solve this problem (if at all)?

## High-Level Approach

- Platform & architecture direction (web, mobile, CLI, API, etc.)
- Key technology choices and rationale
- Major components or services
- External integrations or APIs

## Constraints

- Timeline or budget constraints
- Technical constraints (platform, compatibility, performance)
- Regulatory or compliance requirements
- Team or resource constraints

## Open Questions

- Any unresolved decisions or areas needing further investigation
- Dependencies on external factors
```

Adapt the structure to fit the project — skip sections that don't apply and add sections that are relevant. The goal is a concise, useful reference document, not a lengthy specification.

## Clarifying Questions

When running interactively, ask clarifying questions if needed:

```
When the project is unclear:
- What problem does this solve?
- Who benefits from this?
- What makes this different from alternatives?

When the approach is unclear:
- What's the target platform?
- Are there existing infrastructure constraints?
- What are the performance requirements?
- Are there security/compliance requirements?

When scope is unclear:
- What's in scope for the first version?
- What can be deferred to later?
- Are there hard deadlines?
```

When running autonomously (e.g., from the kickstart endpoint), make reasonable inferences and skip questions.

## Output Location

All files go in `.bot/workspace/product/`:
- `.bot/workspace/product/product.md`

## Success Criteria

- `product.md` created
- File is concise and focused (not a novel)
- Content is project-specific (not a generic template)
- `product.md` starts with a `## Executive Summary` section
- Key decisions and constraints are captured with rationale
