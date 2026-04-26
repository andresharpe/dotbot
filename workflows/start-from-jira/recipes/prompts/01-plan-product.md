---
name: Plan Product (Multi-Repo)
description: Override — brownfield product docs from initiative context instead of greenfield planning
version: 1.0
---

# Product Planning Workflow (Multi-Repo Override)

This workflow creates **brownfield-appropriate product documents** from the initiative context gathered during kickstart. Unlike the default greenfield planning (mission + tech-stack + entity-model), this creates documents suited for cross-repo initiative planning.

## Goal

Create two product documents:
1. **mission.md** — Specification derived from Jira description + business objective + Confluence docs
2. **roadmap-overview.md** — The research plan: what research tasks to create, their timeline, and dependencies

**CRITICAL:** You MUST write both files to `.bot/workspace/product/` in this session.
Existing documents in the briefing or product directory (e.g. spec files from a prior phase) do NOT satisfy this requirement.

**Does NOT create:**
- `tech-stack.md` — Deferred to Phase 3 (refine-artifacts). Tech stacks can only be determined after deep dives reveal the actual technologies per repo.
- `entity-model.md` — Not applicable for brownfield. There is no single entity model across repos.

## Process

### Step 1: Read Initiative Context

Read the briefing files created by Phase 0 (kickstart):

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/interview-summary.md" })
```

Extract:
- Business objective → core mission
- Components & labels → scope boundaries
- Child and linked issues → existing work breakdown
- Confluence documentation → additional specifications
- Reference implementation → comparison baseline
- Programme context → strategic alignment

### Step 2: Read Uploaded Files

Check `.bot/workspace/product/briefing/` for any additional files uploaded by the user. These may include specs, requirements, regulatory documents, or design references.

### Step 3: Create `mission.md`

Write `.bot/workspace/product/mission.md` with:

**IMPORTANT:** The file MUST begin with `## Executive Summary` as the first section after the title. The UI depends on this heading to detect that product planning is complete.

```markdown
# Mission: {INITIATIVE_NAME}

## Executive Summary

2-3 sentence overview of what this initiative aims to achieve, the business driver, and the expected outcome. Derived from the Jira description and Confluence documentation.

## Business Objective

Expanded description of the business need, regulatory requirements, or strategic goal driving this initiative. Include timeline pressures, compliance deadlines, or market drivers.

## Scope

### In Scope
- Systems and repos expected to be affected
- Types of changes anticipated (code, configuration, database, infrastructure)
- Integration points

### Out of Scope
- What this initiative explicitly does NOT cover
- Adjacent work that should be separate initiatives

### Assumptions
- Key assumptions about the environment, dependencies, and constraints

## Success Criteria

- Measurable outcomes that define "done" for this initiative
- Compliance or certification requirements
- Performance targets

## Constraints

- Timeline constraints (regulatory deadlines, programme milestones)
- Technical constraints (platform versions, compatibility requirements)
- Organisational constraints (team availability, budget, approvals)

## Reference Implementation

- Which existing implementation serves as the template
- Key similarities and differences
- Lessons from the reference that apply here

## Stakeholders

| Role | Name | Responsibility |
|------|------|----------------|
(from jira-context.md team section)

## Related Documentation

- Links to Jira tickets, Confluence pages, and other references
(from jira-context.md)
```

### Step 5: Extract Known Repos → Seed `research-repos.md`

Scan all briefing documents (`jira-context.md`, `interview-summary.md`, and any files in `briefing/`) for explicitly named repositories, Azure DevOps project references, or git URLs. Look for:

- Repository names mentioned in Jira descriptions, Confluence pages, or uploaded specs
- ADO project/repo references (e.g., `Project/RepoName`, Azure DevOps URLs)
- Git clone URLs (`https://dev.azure.com/...`, `git@ssh.dev.azure.com:...`)
- References like "the Payments repo", "Checkout service clone", etc.

**If repos are found**, write a seed `.bot/workspace/product/research-repos.md` using the standard tier-table format:

```markdown
# Repos Potentially Affected

## Context

Seed file generated from briefing documents. Repos listed below were explicitly named in the initiative briefing. Impact and tier classifications are preliminary — based on how the repo was referenced, not code analysis.

If Sourcebot research runs later, it will merge with this seed (seed entries take precedence as they reflect user-briefed repos).

---

## Tier 1: Core Feature Repos (Directly Affected)

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|
| {RepoName} | {ADOProject or "TBD"} | {Why it was mentioned in briefing} | {HIGH or MEDIUM — HIGH if briefing indicates direct changes needed} |

---

## Summary: Key Repos by Priority

### Must-change (repos where changes are definitely required)

1. {RepoName} — {one-line from briefing context}
```

Rules:
- Place repos in Tier 1 unless the briefing clearly indicates a supporting/peripheral role
- Default to HIGH impact for repos explicitly named as needing changes; MEDIUM if mentioned but role is unclear
- Use the ADO project name if identifiable from context; otherwise use `TBD`
- **If NO repos are mentioned in any briefing document, do NOT create `research-repos.md`** — this preserves the existing skip behavior for downstream phases

### Step 6: Create `roadmap-overview.md`

Write `.bot/workspace/product/roadmap-overview.md` with the research plan:

```markdown
# Roadmap Overview: {INITIATIVE_NAME}

## Research Plan

This document outlines the research phases that will inform the implementation plan.

### Phase 1: Foundational Research

Three independently toggleable research streams (each is an optional kickstart phase):

| # | Task | Methodology | Dependencies | Output |
|---|------|-------------|--------------|--------|
| 2a | Internet Research | `public.md` | None | `research-internet.md` |
| 2b | Atlassian Research | `atlassian.md` | None | `research-documents.md` |
| 2c | Repository Impact Scan | `repos.md` | None | `research-repos.md` |

### Phase 2: Deep Dives

Per-repo deep dives for MEDIUM+ impact repos (created after Phase 1 completes):

- Each repo gets a `repo-deep-dive.md` methodology task
- Output: `briefing/repos/{RepoName}.md` per repo
- Repos are cloned to `repos/{RepoName}/` on initiative branches

### Phase 2b-2c: Implementation Research & Planning

- Synthesize deep dives into `04_IMPLEMENTATION_RESEARCH.md`
- Create per-repo code-level plans: `{RepoName}_Plan.md`

### Phase 3: Artifact Refinement

- Cross-reference all findings
- Generate `03_CROSS_CUTTING_CONCERNS.md`, `05_DEPENDENCY_MAP.md`, `06_OPEN_QUESTIONS.md`
- Update `mission.md` with refined understanding
- Create `tech-stack.md` reverse-engineered from repo deep dives

### Phase 4: Publish to Atlassian

- Create/update Jira epic structure
- Post research to Confluence
- Link tickets to pages

### Phase 5-6: Implementation & Remediation

- Per-repo implementation from plans
- Build/test verification and fixes
- Outcomes and remediation documents per repo

### Phase 7: Handoff

- Per-repo handoff documents with individual tasks
- Push initiative branches
- Create draft PRs

## Timeline Considerations

- Research phases (1-3) can often proceed in days, not weeks
- Implementation timeline depends on deep dive findings
- Remediation time is unpredictable — budget for iteration

## Key Dependencies

- Atlassian MCP server availability (Phase 0, Phase 4)
- Azure DevOps access and PAT configuration (Phase 2+)
- External provider/vendor timelines (may block implementation)
- Stakeholder availability for open questions (Phase 3)
```

### Step 7: Verify Required Outputs

Before declaring this phase complete, verify both required files exist:

- [ ] `.bot/workspace/product/mission.md` — MUST exist and begin with `## Executive Summary`
- [ ] `.bot/workspace/product/roadmap-overview.md` — MUST exist

**If either file is missing, create it now.** Do NOT mark the phase complete until both files have been written.
Do not rely on documents created in a previous session (spec files, design docs, etc.) as a substitute for these deliverables.

## Clarifying Questions

After creating all product documents, review them for gaps, ambiguities, or missing information that would meaningfully benefit from user input. If you find such gaps, write `.bot/workspace/product/clarification-questions.json`:

```json
{
  "questions": [
    {
      "id": "q1",
      "question": "Specific question about a gap or ambiguity",
      "context": "What you found in the briefing and why this needs clarification",
      "options": [
        { "key": "A", "label": "Option label", "rationale": "Why this option" },
        { "key": "B", "label": "Option label", "rationale": "Why this option" }
      ],
      "recommendation": "A"
    }
  ]
}
```

Rules:
- Each question must have 2-5 options with clear rationale
- Option keys are single letters (A through E); `recommendation` indicates the suggested choice
- Focus on gaps that would change the mission, scope, or research plan — not trivial details
- If the briefing is sufficiently clear, do NOT write the file — no interruption needed
- The runtime will detect this file and surface questions to the user via the UI

## Output Location

All files go in `.bot/workspace/product/`:
- `.bot/workspace/product/mission.md`
- `.bot/workspace/product/roadmap-overview.md`
- `.bot/workspace/product/research-repos.md` (only if repos found in briefing docs)

## Success Criteria

- `mission.md` and `roadmap-overview.md` created
- `mission.md` starts with `## Executive Summary` section
- Content is derived from initiative context (not generic templates)
- Roadmap reflects the multi-repo research lifecycle
- If briefing docs name repos, `research-repos.md` seed file created with standard tier-table format
- If gaps found, `clarification-questions.json` written with structured options
- No `tech-stack.md` or `entity-model.md` created
