---
name: Plan Implementation
description: Create per-repo code-level implementation plans from deep dives and implementation research
version: 1.0
---

# Plan Implementation

Creates detailed, code-level implementation plans for each affected repository. Each plan is specific enough for an engineer (or AI agent) to implement without further research.

## Prerequisites

- `04_IMPLEMENTATION_RESEARCH.md` must exist (implementation research synthesis)
- Deep dive reports must exist for all target repos
- `jira-context.md` must exist

> **Heartbeat:** This phase can run 15-30 minutes. Call `steering_heartbeat` with a status update every 5 minutes to keep the dashboard informed.

## Your Task

### Step 1: Read Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/briefing/04_IMPLEMENTATION_RESEARCH.md" })
```

### Step 2: Load Plan Template

```
Read({ file_path: ".bot/recipes/implementation/plan.md" })
```

### Step 3: Identify Target Repos

Read `research-repos.md` and the implementation research to determine which repos need implementation plans. Typically these are the MEDIUM+ impact repos that had deep dives.

### Step 4: Create Per-Repo Plans

For each target repo, read its deep dive report and produce a plan file.

**Read the deep dive:**
```
Read({ file_path: ".bot/workspace/product/briefing/repos/{RepoName}.md" })
```

**Write the plan to the per-repo workspace:**
```
repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md
```

Each plan must include:

1. **Design Decisions Table**

| Decision | Choice | Rationale |
|----------|--------|-----------|

Key architectural and implementation choices with justification.

2. **Implementation Order**

Ordered list of changes within this repo, noting what's blocked vs what can proceed.

3. **Per-File Changes**

For each file to modify or create:
- File path
- Change type (modify / create / clone from reference)
- Specific changes (with code snippets showing the pattern)
- What's blocked (if any external dependency)

4. **Configuration Entries**

| Config File | Key | Value | Description |
|-------------|-----|-------|-------------|

5. **Database Scripts** (if applicable)

| Script | Purpose | Complexity |
|--------|---------|------------|

6. **Unit Test Specifications**

| Test File | Test Cases | Coverage Target |
|-----------|------------|-----------------|

7. **Verification Commands**

Build, test, and lint commands to verify the implementation.

8. **What's Blocked**

Items that cannot proceed until external dependencies are resolved. Include a stub/placeholder approach for unblocked progress.

### Step 5: Determine Implementation Order Across Repos

Based on the cross-repo dependencies from `04_IMPLEMENTATION_RESEARCH.md`, produce a recommended implementation sequence:

1. Which repos should be implemented first (they produce outputs consumed by others)
2. Which repos can be implemented in parallel
3. Which repos are blocked on external dependencies

Include this as a summary at the end of each plan and reference `05_DEPENDENCY_MAP.md` if it exists.

## Output

One plan file per repo:
```
repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md
```

## Critical Rules

- Plans must be specific enough to implement without reading the deep dive again
- Include code snippets showing the pattern to follow (from the reference implementation)
- Explicitly mark blocked items with stubs
- Include verification commands for each repo
- Create the per-repo `.bot/workspace/` directory structure if it doesn't exist
- Do NOT implement code — only create the plans
- Do NOT create tasks — the implementation workflow (09) handles task creation
