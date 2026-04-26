---
name: Implement Changes
description: Execute per-repo implementation from plans, commit to initiative branches, produce outcomes
version: 2.0
---

# Implement Changes

Execute the implementation plans for each affected repository. All changes are committed to the `initiative/{JIRA_KEY}` branch created at clone time.

## Prerequisites

- Implementation tasks must exist in `tasks/todo/` (created by `09-create-impl-tasks.md`)
- Implementation plans must exist: `repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md`
- Repos must be cloned to `repos/{RepoName}/` with initiative branch checked out

## Execution (Per Task)

When each implementation task executes:

### 1. Read the plan

```
Read({ file_path: "repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md" })
```

### 2. Implement in order

Follow the plan's implementation order. For each file change:
- Read the reference implementation file (cited in the plan)
- Create or modify the target file following the pattern
- Use TODO markers for blocked items: `// TODO({keyword}): description`

### 3. Build and test

Run the verification commands from the plan. Document any failures.

### 4. Commit

```bash
cd repos/{RepoName}
git add -A
git commit -m "{change description}

[{JIRA_KEY}] {INITIATIVE_NAME}
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### 5. Write outcomes

Using the outcomes template (`prompts/implementation/outcomes.md`), write:
```
repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md
```

Document:
- Files created (count + table)
- Files modified (count + table)
- Build status
- Design decisions made during implementation
- TODO markers left in code
- What's next (blocked items, follow-ups)

## Output

Per repo:
- Code changes committed to `initiative/{JIRA_KEY}` branch
- `repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md`

## Critical Rules

- Follow the plan — don't improvise unless the plan is clearly wrong
- Commit to the initiative branch only — do NOT push (that's Phase 7)
- Use TODO markers for blocked items — don't skip them silently
- Write outcomes even if implementation is partial
- Document ALL files created and modified — the handoff depends on this
- Build verification is mandatory — record pass/fail regardless
- Respect cross-repo implementation order from dependency map
