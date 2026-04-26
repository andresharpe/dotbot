---
name: Draft System Docs
description: Generate per-repo handoff docs with individual tasks, push branches, create draft PRs
version: 1.0
---

# Draft System Docs (Handoff)

The final phase of the multi-repo initiative lifecycle. For each affected repo, this workflow:
1. Generates a handoff document with individual dotbot tasks
2. Pushes the initiative branch to origin
3. Creates a draft PR

## Prerequisites

- Implementation outcomes must exist: `{RepoName}_Outcomes.md`
- Remediation reports should exist: `{RepoName}_Remediation.md`
- `jira-context.md` must exist for Jira key and initiative name
- `.env.local` must have valid AZURE_DEVOPS_PAT
- `az` CLI must be available for PR creation

> **Heartbeat:** This phase can run 15-30 minutes. Call `steering_heartbeat` with a status update every 5 minutes to keep the dashboard informed.

## Your Task

### Step 1: Read Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
```

Extract:
- **JIRA_KEY** (e.g., `PROJ-1234`)
- **INITIATIVE_NAME** (e.g., `Payment Gateway Upgrade`)
- **ADO_ORG_URL** (from .env.local)

Check repo status:
```
mcp__dotbot__repo_list({})
```

Process repos with `status: "implemented"` or `status: "handoff-ready"` (skip if handoff already exists).

### Step 2: For Each Repo — Generate Handoff Document

Read the implementation artifacts:
```
Read({ file_path: "repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md" })
Read({ file_path: "repos/{RepoName}/.bot/workspace/product/{RepoName}_Remediation.md" })
Read({ file_path: ".bot/workspace/product/briefing/repos/{RepoName}.md" })
```

Also read the implementation plan for context:
```
Read({ file_path: "repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md" })
```

Write the handoff document to:
```
repos/{RepoName}/.bot/workspace/product/{RepoName}-handoff.md
```

#### Handoff Document Structure

```markdown
# Handoff: {RepoName}

> **Initiative**: [{JIRA_KEY}] {INITIATIVE_NAME}
> **Branch**: initiative/{JIRA_KEY}
> **Date**: {DATE}
> **Status**: Draft — review before merging

## Executive Summary

2-3 sentence summary: what was done, what remains, overall status.

## What Was Changed

### Files Created ({COUNT})

| # | File | Purpose |
|---|------|---------|
(from Outcomes document)

### Files Modified ({COUNT})

| # | File | Change Description |
|---|------|--------------------|
(from Outcomes document)

### Configuration Changes

(config entries added — from Outcomes)

### Database Scripts

(scripts created — from Outcomes, if applicable)

## Build & Test Status

| Check | Status | Notes |
|-------|--------|-------|
| Compilation | Pass/Fail | |
| Unit Tests | N/N pass | |
| Integration Tests | N/A | |

(from Remediation document)

## Issues Encountered & Resolved

(from Remediation document — compilation errors, test failures, environment issues)

## Known Gotchas

Snags, frustrations, and quirks encountered during research and implementation that a downstream developer should know about:

- (from deep dive: naming convention quirks, undocumented dependencies)
- (from implementation: unexpected behavior, config gotchas)
- (from remediation: auth issues, build quirks, pre-existing problems)

> These are hard-won lessons from the research and implementation process.
> They save the next developer from hitting the same walls.

## Remaining Work

### TODO Markers in Code

| # | File | Line | Description | Blocked On |
|---|------|------|-------------|------------|
(from Outcomes — searchable markers like `// TODO({keyword}):`)

### Blocked Items

| Item | Blocker | Expected Resolution |
|------|---------|---------------------|
(from Outcomes + Remediation)

### Follow-Up Tasks

Items that should be completed after this PR is merged:

(list specific follow-up work)

## Individual Tasks

Each discrete change from this initiative is broken down into an individual task below. A developer (or dotbot instance) picking up this repo should be able to work through these tasks independently.

### Task 1: {Title}

**Description**: What was done and what to verify.
**Files**: List of files involved.
**Acceptance Criteria**:
- Specific, verifiable criteria
**Context**: Why this was done, what patterns were followed, any gotchas.
**Status**: Complete / Partial / TODO

### Task 2: {Title}
(repeat for each discrete change)

...

## References

| Document | Path |
|----------|------|
| Deep Dive | `briefing/repos/{RepoName}.md` |
| Implementation Plan | `repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md` |
| Outcomes | `repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md` |
| Remediation | `repos/{RepoName}/.bot/workspace/product/{RepoName}_Remediation.md` |
| Initiative | `briefing/jira-context.md` |
| Implementation Research | `briefing/04_IMPLEMENTATION_RESEARCH.md` |
```

#### Task Generation Rules

Each individual task in the handoff document should:
1. Correspond to a discrete change (new file, modified file, config entry, DB script)
2. Include full context — what was done, what pattern was followed, what to verify
3. Carry forward snags/gotchas from earlier phases
4. Be independently completable — a developer should understand it without reading the whole handoff
5. Include status: "Complete" if implemented, "Partial" if stub/TODO, "TODO" if not started

### Step 3: Push Branch

```bash
cd repos/{RepoName}
git push -u origin initiative/{JIRA_KEY}
```

If push fails:
- Check `.env.local` for valid AZURE_DEVOPS_PAT
- Check network connectivity
- Document the failure and continue to next repo

### Step 4: Create Draft PR

```bash
az repos pr create \
  --repository {RepoName} \
  --source-branch initiative/{JIRA_KEY} \
  --target-branch {default_branch} \
  --title "[{JIRA_KEY}] {INITIATIVE_NAME}" \
  --description @repos/{RepoName}/.bot/workspace/product/{RepoName}-handoff.md \
  --draft \
  --org {ADO_ORG_URL} \
  --project {PROJECT}
```

The `default_branch` was stored during `repo_clone` (typically `main` or `master`).

If PR creation fails:
- Check `az` CLI is logged in
- Check branch was pushed successfully
- Document the failure for manual follow-up

### Step 5: Record Results

After processing all repos, create a summary:

```
.bot/workspace/product/briefing/08_HANDOFF_STATUS.md
```

| Repo | Handoff Doc | Branch Pushed | Draft PR | PR URL | Notes |
|------|-------------|---------------|----------|--------|-------|
(one row per repo with status of each step)

## Output

Per repo:
1. `repos/{RepoName}/.bot/workspace/product/{RepoName}-handoff.md`
2. Branch `initiative/{JIRA_KEY}` pushed to origin
3. Draft PR created

Plus:
4. `briefing/08_HANDOFF_STATUS.md` — summary of all handoff operations

## Critical Rules

- The handoff doc is the **bridge** between initiative-level and repo-level work
- Individual tasks must be **independently understandable** — don't assume the reader has initiative context
- Carry forward **gotchas and snags** — these save downstream developers significant time
- Push as **draft PR** — signals "here's what the initiative planned" not "this is ready to merge"
- PR title format: `[{JIRA_KEY}] {INITIATIVE_NAME}` — enables Jira auto-linking
- Do NOT force push — if the branch already exists on remote, handle gracefully
- Do NOT mark PRs as ready for review — they are drafts
- If any step fails, document the failure and continue to the next repo
