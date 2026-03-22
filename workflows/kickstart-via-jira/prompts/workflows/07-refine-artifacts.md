---
name: Refine Artifacts
description: Cross-reference findings, fill gaps, create synthesis artifacts, update mission and tech-stack
version: 1.0
---

# Refine Artifacts

After all deep dives and implementation research complete, this workflow performs cross-cutting analysis to fill gaps, resolve contradictions, and produce synthesis artifacts that no individual research task could create.

## Prerequisites

- All deep dive reports in `briefing/repos/*.md`
- `04_IMPLEMENTATION_RESEARCH.md` exists
- `mission.md` exists (from Phase 0.5)
- `jira-context.md` exists

> **Heartbeat:** This phase can run 15-30 minutes. Call `steering_heartbeat` with a status update every 5 minutes to keep the dashboard informed.

## Your Task

### Step 1: Read All Artifacts

Read all research artifacts:
- `jira-context.md`
- `research-documents.md`, `research-internet.md`, `research-repos.md`
- `04_IMPLEMENTATION_RESEARCH.md`
- All `repos/*.md` deep dive reports
- Current `mission.md`

### Step 2: Generate Deep Dive Index

Write `.bot/workspace/product/briefing/repos/00_INDEX.md`:

```markdown
# Deep Dive Index

| Repo | Project | Tier | Impact | Overall Effort | Key Risks | Status |
|------|---------|------|--------|----------------|-----------|--------|
(one row per deep dive, extracted from each report's overview and effort sections)

## Summary Statistics

- Total repos analysed: N
- HIGH impact: N
- MEDIUM impact: N
- Total estimated effort: (aggregated T-shirt sizes)
- Critical path repos: (list)
```

### Step 3: Generate Cross-Cutting Concerns

Write `.bot/workspace/product/briefing/03_CROSS_CUTTING_CONCERNS.md`:

Analyse all deep dives for shared patterns:

1. **Shared Dependencies** — NuGet packages, message contracts, database schemas used by multiple repos. Changes here ripple across repos.

2. **Common Patterns** — Implementation patterns that appear in multiple repos (strategy patterns, config-driven behavior, etc.). Document once, reference from plans.

3. **Sequencing Recommendations** — Which repos must change first because others consume their output. Build-order dependencies.

4. **Shared Infrastructure** — Queues, topics, storage accounts, pipelines used by multiple repos.

5. **Common Risks** — Risks that affect multiple repos (e.g., NuGet feed auth issues, shared DB schema changes).

6. **Skill/Knowledge Requirements** — Technologies or patterns that require specific expertise across multiple repos.

### Step 4: Generate Dependency Map

Write `.bot/workspace/product/briefing/05_DEPENDENCY_MAP.md`:

Analyse all deep dive "Dependencies" sections and implementation research to produce:

1. **Build-Order Dependencies** — Repos that must be implemented first because others consume their output.

2. **Shared Contract Dependencies** — Repos sharing NuGet packages, protobuf definitions, or message schemas.

3. **Database Dependencies** — Repos that read from tables written by other repos.

4. **Config Dependencies** — Repos that reference values defined in other repos' configs.

5. **Test Dependencies** — Repos whose integration tests require other repos' changes.

**Output format:**
- Text-based dependency graph (repo A -> repo B with dependency type)
- Recommended implementation sequence (ordered list with rationale)
- Parallel swim lanes (which repos can run concurrently)
- Critical path (longest sequential chain)
- Circular or unresolvable dependencies flagged

### Step 5: Generate Open Questions Register

Write `.bot/workspace/product/briefing/06_OPEN_QUESTIONS.md`:

Extract every open question, ambiguity, and gap from ALL research and deep dive documents:

| ID | Category | Question | Source | Owner | Status | Impact If Unresolved |
|----|----------|----------|--------|-------|--------|----------------------|

Categories:
- **Business Case** — strategic justification, scope, priority
- **Requirements** — functional gaps, regulatory clarifications
- **Development** — technical design decisions, blocked items
- **Acceptance** — definition of done, sign-off criteria
- **UAT** — test scenarios, test data, environment requirements

### Step 6: Update `mission.md`

Update `.bot/workspace/product/mission.md` with refined understanding from research:
- Refine scope based on actual repo analysis
- Update constraints based on discovered dependencies
- Add technical findings that affect the business case
- Keep the `## Executive Summary` as the first section

### Step 7: Create `tech-stack.md`

Write `.bot/workspace/product/tech-stack.md` — reverse-engineered from repo deep dives:

```markdown
# Tech Stack

## Languages & Frameworks

| Language | Framework | Version | Repos Using |
|----------|-----------|---------|-------------|

## Databases

| Database | Type | Repos Using |
|----------|------|-------------|

## Shared Packages

| Package | Version | Purpose | Repos Using |
|---------|---------|---------|-------------|

## Infrastructure

| Component | Type | Purpose |
|-----------|------|---------|

## External Services

| Service | Provider | Purpose | Repos Using |
|---------|----------|---------|-------------|
```

## Output

6 files created or updated:
1. `briefing/repos/00_INDEX.md` — deep dive summary table
2. `briefing/03_CROSS_CUTTING_CONCERNS.md` — shared patterns and dependencies
3. `briefing/05_DEPENDENCY_MAP.md` — implementation ordering
4. `briefing/06_OPEN_QUESTIONS.md` — consolidated questions register
5. `mission.md` — updated with research findings
6. `tech-stack.md` — created from repo analysis

## Critical Rules

- Cross-reference all deep dives — don't just summarize individually
- Flag contradictions between deep dive findings
- The dependency map must be actionable — an engineer should know what to build first
- Open questions must be numbered and categorized — this is a tracking register
- Keep `mission.md` `## Executive Summary` as the first section
- `tech-stack.md` is derived from evidence, not assumed
