---
name: Implementation Research
description: Synthesize all deep dives into an actionable implementation guide
version: 1.0
---

# Implementation Research

After all deep dives complete, synthesize the findings into a single actionable implementation guide. This bridges the gap between research ("what exists") and implementation ("what to build and how").

## Prerequisites

- All deep dive reports must exist in `.bot/workspace/product/briefing/repos/`
- Foundational research (00, 01, 02) must be complete
- `jira-context.md` must exist

## Your Task

### Step 1: Read All Research Artifacts

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/research-documents.md" })
Read({ file_path: ".bot/workspace/product/research-internet.md" })
Read({ file_path: ".bot/workspace/product/research-repos.md" })
```

Then read all deep dive reports from `.bot/workspace/product/briefing/repos/*.md`.

### Step 2: Load Implementation Research Template

```
Read({ file_path: ".bot/recipes/implementation/research.md" })
```

Follow this template's structure to produce the synthesis document.

### Step 3: Synthesize

Produce `.bot/workspace/product/briefing/04_IMPLEMENTATION_RESEARCH.md` covering:

1. **Platform/System Overview** — Architecture, components, data flow across all affected repos. How the repos interact. Draw from all deep dive "Repository Overview" and "Dependencies" sections.

2. **How Previous Analogous Implementations Were Done** — Pattern analysis across reference implementations found in deep dives. Common approach, variations, timeline. Comparison table.

3. **Initiative-Specific Requirements** — From research-internet.md: regulatory, technical, business requirements specific to this initiative.

4. **What Differs from Existing Implementations** — Unique aspects of this initiative vs the reference. New patterns needed, gaps in existing infrastructure.

5. **Extension Points** — Where the existing platform is designed for new entities (config-driven, strategy patterns, enum extensions) vs where new code is required.

6. **Configuration Model** — Across all repos: what can be enabled via config/data alone vs what requires code changes. Consolidate the "Configuration-Driven vs Code-Driven" sections from deep dives.

7. **Technical Implementation Approach per Service** — For each affected repo: files to modify, new files to create, config entries, status mappings. Consolidate from deep dives but add cross-repo context.

8. **Dependencies and Blockers** — What can proceed now vs what's blocked. External dependencies (vendors, APIs, credentials). Internal dependencies (repo A must be done before repo B).

9. **Open Questions Requiring Stakeholder Input** — Consolidate from all research. Number sequentially, categorize, identify owner where possible.

10. **Risks with Mitigations** — Consolidate risk flags from all deep dives. Add cross-cutting risks (e.g., all repos share a NuGet package that needs updating).

11. **Delivery Estimate** — Based on deep dive effort estimates. Total across repos. Identify critical path and parallel work lanes.

### Step 4: Write Output

Write the synthesis to:
```
.bot/workspace/product/briefing/04_IMPLEMENTATION_RESEARCH.md
```

## Output

A single comprehensive document that answers: "What do we need to build, how should we build it, what's blocking us, and how long will it take?"

## Critical Rules

- Do NOT copy-paste from deep dives — synthesize and cross-reference
- Every claim must cite the source deep dive or research document
- Flag contradictions between deep dive findings
- Identify cross-repo dependencies that no individual deep dive could see
- Include a delivery estimate with critical path analysis
- Do NOT create tasks — this is a document synthesis workflow
