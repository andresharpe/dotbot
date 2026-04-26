---
name: Plan Product From PR
description: Create mission and roadmap documents from pull request context
version: 1.0
---

# Product Planning From Pull Request Context

Create two brownfield planning artifacts from the resolved PR context:

1. `.bot/workspace/product/mission.md`
2. `.bot/workspace/product/roadmap-overview.md`

Do not create `tech-stack.md` or `entity-model.md` for this profile.

## Step 1: Read the Context

Read:

```text
Read({ file_path: ".bot/workspace/product/briefing/pr-context.md" })
```

If `.bot/workspace/product/interview-summary.md` exists, read it as well and treat it as clarified user intent.

## Step 2: Create `mission.md`

Write `.bot/workspace/product/mission.md`.

The file must start with `## Executive Summary` immediately after the title.

Use this structure:

```markdown
# Mission: {PR_TITLE}

## Executive Summary

2-3 sentences explaining what the PR is trying to accomplish, what business or operational problem it addresses, and what outcome the team should preserve while continuing the work.

## Problem Statement

Translate the PR description and linked issues into the underlying problem or opportunity.

## In Scope

- Capabilities already touched by the PR
- Adjacent work clearly implied by the PR context
- Validation or documentation work that must happen for this PR to land safely

## Out of Scope

- Work not evidenced by the PR context
- Nice-to-have follow-ups that should not block this initiative

## Success Criteria

- Concrete outcomes that would make the PR and its follow-up work complete
- Include testing, rollout, and stakeholder expectations when supported by context

## Constraints And Risks

- Branching, release, or rollout constraints
- Risk areas suggested by linked issues or changed files
- Unknowns that still need analysis

## Evidence From The PR

### Linked Issues
- Summarize the linked issues as planning signals.

### Changed Surface
- Summarize the affected files and what they imply about system boundaries.
```

## Step 3: Create `roadmap-overview.md`

Write `.bot/workspace/product/roadmap-overview.md` with a concrete implementation roadmap derived from the PR context.

Use this structure:

```markdown
# Roadmap Overview: {PR_TITLE}

## Current Baseline

- What the current PR already covers
- What still appears incomplete or risky

## Workstreams

| Workstream | Why It Exists | Evidence From PR | Expected Outcome |
|------------|---------------|------------------|------------------|
| ... | ... | ... | ... |

## Proposed Sequence

### Phase 1: Confirm Intent And Scope
- Analysis or stakeholder alignment work required before broadening the change

### Phase 2: Complete Implementation
- Code, configuration, and data changes implied by the PR and linked issues

### Phase 3: Verify And Harden
- Tests, quality gates, and edge-case checks required by the touched files

### Phase 4: Release And Communicate
- Documentation, rollout, monitoring, or handoff work suggested by the PR context

## Dependencies

- Upstream tasks or approvals implied by linked issues
- Cross-cutting dependencies between changed areas

## Outstanding Unknowns

- Questions that still need answers before execution can be considered safe
```

## Rules

- Ground all content in `pr-context.md` and `interview-summary.md` when present.
- Keep this brownfield-focused. You are extending or stabilizing existing work, not inventing a greenfield product.
- Do not create tasks in this phase.
