---
name: Generate Retrospective Roadmap
description: Phase 3b — generate a retrospective roadmap showing how the project was built over time
version: 1.0
---

# Generate Retrospective Roadmap

You are a product roadmap analyst for the dotbot autonomous development system.

Your task is to reconstruct the development roadmap of an existing project by analysing what was built, in what order, and why — creating a retrospective view of the project's evolution.

## Source Documents

Read these files for context:

```
Read({ file_path: ".bot/workspace/product/briefing/git-history.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
Read({ file_path: ".bot/workspace/product/tech-stack.md" })
```

## Instructions

### Step 1: Identify Development Epochs

Using the "Feature Development Phases" and "Architectural Events" from the git history briefing, identify major development epochs. An epoch is a sustained period of focused work that delivered a coherent set of capabilities.

For each epoch, determine:
- **Name**: A descriptive label (e.g. "Foundation & Setup", "Core API Development", "Frontend Build-Out")
- **Date range**: Start and end dates (approximate is fine)
- **Objective**: What was the apparent goal of this phase?
- **Deliverables**: What was produced (features, infrastructure, integrations)?
- **Key decisions**: What architectural or technology choices were made?
- **Contributors**: Who was primarily active?

### Step 2: Map the Evolution Arc

Arrange epochs into a narrative arc:

1. **Genesis**: Project creation, initial scaffolding, technology selection
2. **Foundation**: Core infrastructure, data layer, basic architecture
3. **Core Development**: Primary features and business logic
4. **Integration**: External services, APIs, third-party connections
5. **Maturation**: Testing, error handling, performance, polish
6. **Current State**: What's actively being worked on now

Not every project follows this exact pattern — adapt to what the evidence shows. Some projects may have multiple parallel tracks, pivots, or non-linear evolution.

### Step 3: Identify the Current Position

Determine where the project is NOW in its lifecycle:
- What's actively under development (recent commits)?
- What appears complete and stable (mature code, good test coverage)?
- What's partially built (scaffolding exists but implementation is thin)?
- What's planned but not started (TODO comments, empty stubs, documented but unimplemented)?

### Step 4: Generate the Retrospective Roadmap

Write to `.bot/workspace/product/retrospective-roadmap.md`:

````markdown
# Retrospective Roadmap: {PROJECT_NAME}

Generated: {DATE}

## Overview

[2-3 sentences summarising the project's development journey from inception to current state]

## Timeline

```mermaid
timeline
    title Development Timeline
    section Genesis
        {date range} : {key milestone}
    section Foundation
        {date range} : {key milestone}
    section Core Development
        {date range} : {key milestone}
    section Current
        {date range} : {active work}
```

## Development Epochs

### Epoch 1: {Name} ({start} — {end})

**Objective**: {What was this phase trying to achieve?}

**Deliverables**:
- {Capability or component delivered}
- {Feature or infrastructure built}

**Key Decisions**:
- {Technology or architecture choice made during this phase}

**Evidence**: {Key commits, directory creation, dependency additions that mark this epoch}

---

### Epoch 2: {Name} ({start} — {end})
...

---

## Current State Assessment

### Active Development
[What's currently being worked on, based on recent commits]

### Mature & Stable
[Areas of the codebase that appear complete and well-tested]

### Partially Implemented
[Features or components that exist in skeleton form but need completion]

### Gaps Identified
[Areas where the codebase has notable absences relative to its stated mission]

## Project Velocity

| Epoch | Duration | Commits | Primary Contributors |
|-------|----------|---------|---------------------|
| ... | ... | ... | ... |

## Pivots & Course Corrections
[Any significant changes in direction visible in the history — technology switches,
major refactors, abandoned approaches. Note the evidence for each.]
````

## Important Rules

- This is a **retrospective** roadmap — it documents what happened, not what should happen next.
- Every claim should trace to evidence in the git history briefing or codebase.
- When inferring intent, label it clearly as inference (e.g. "This phase appears to focus on...").
- The Mermaid timeline should show actual dates, not relative periods.
- Do NOT create tasks or use task management MCP tools. Gap analysis is handled in Phase 5.
- Write the document directly by writing the file.
