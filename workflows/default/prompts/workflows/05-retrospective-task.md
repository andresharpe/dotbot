---
name: Retrospective Task Documentation
version: 1.0
---

# Retrospective Task Documentation

Document completed work with proper task/plan files matching live-session quality.

## When to Use
- Work completed outside tracked sessions
- Backfilling historical documentation

## Prerequisites

Gather before starting:
1. **Work**: Problem solved, approach, key decisions
2. **Files**: Created, modified, deleted
3. **Timeline**: Start/end times, effort estimate
4. **Validation**: Success criteria met
5. **Context** (optional): Commits, related issues

## Implementation

### Step 1: Generate Task ID

Generate UUID, extract first 8 chars as short ID:
```
UUID: db728bce-f775-43b8-9d21-42016f7efe80 → Short ID: db728bce
```

### Step 2: File Names

Format: `{task-slug}-{short-id}`

Paths:
- Task: `.bot/workspace/tasks/done/{task-slug}-{short-id}.json`
- Plan: `.bot/workspace/plans/{task-slug}-{short-id}-plan.md`

### Step 3: Read Templates

Load samples for structure:
- `.bot/workspace/tasks/samples/sample-task-retrospective.json`
- `.bot/workspace/tasks/samples/sample-plan-retrospective.md`

### Step 4: Create Task JSON

**Required fields**:
- `id`: Full UUID
- `name`, `description`: Task details with problem/approach/decisions
- `category`: feature|bugfix|refactor|infrastructure|documentation
- `status`: "done"
- `priority`: Default 10
- `effort`: XS|S|M|L|XL
- `created_at`, `started_at`, `completed_at`: ISO 8601 UTC
- `plan_path`: Path to plan markdown
- `steps`: High-level steps taken
- `acceptance_criteria`: Success criteria
- `files_created`, `files_modified`, `files_deleted`: File path arrays

**Optional**: `commits`, `execution_activity_log`, `analysis`, `dependencies`, `applicable_standards`, `applicable_agents`, `human_hours`, `ai_hours`

**Notes**: Remove `_comment`/`_note` fields; use relative paths from repo root.

### Step 5: Create Plan Markdown

**Required sections**: Problem Statement, Current State, Proposed Solution, Implementation Steps, Success Criteria

**Optional**: Files Modified/Created, Testing/Verification, Notes/Learnings

## Validation Checklist

- [ ] Valid JSON with all required fields
- [ ] `plan_path` points to correct plan file
- [ ] Relative paths from repo root
- [ ] No `_comment`/`_note` fields
- [ ] Plan has all required sections
- [ ] Filenames match: `{task-slug}-{short-id}[.json|-plan.md]`
- [ ] **Dates accurate**: Verify `created_at`, `started_at`, `completed_at` reflect actual times

## Data Format Requirements

### Timestamps

**CRITICAL**: Before saving, verify all dates are accurate and use ISO 8601 UTC: `yyyy-MM-ddTHH:mm:ssZ`

✓ `2026-01-24T07:54:09Z`
✗ `24/01/2026 07:54:09` | `01/24/2026` | `2026-01-24 07:54:09`

Applies to: `created_at`, `started_at`, `completed_at`, `updated_at`, activity log timestamps.

### Privacy

Before commit:
1. No local paths (`C:\Users\`, `/home/`, `/Users/`) — use relative paths
2. No secrets (API keys, tokens, passwords)
3. Run `.bot/hooks/verify/00-privacy-scan.ps1`

## Quality Standards

- Provide context for unfamiliar readers
- Include specifics: file names, decisions, outcomes
- Accurate and factual only
- Valid JSON/markdown formatting

## Commit & Push Requirements

**CRITICAL**: Never push directly to master bypassing CI checks.

1. Create a feature branch: `git checkout -b docs/retrospective-{task-slug}`
2. Commit changes to the branch
3. Push branch: `git push -u origin docs/retrospective-{task-slug}`
4. Create PR: `gh pr create --title "docs: retrospective for {task-name}" --body "..."`
5. Wait for CI (`build-and-test`) to pass
6. Merge PR (or ask user to merge)

**Never** use `--force` or bypass branch protection rules.
