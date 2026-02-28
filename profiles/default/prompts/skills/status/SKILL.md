---
name: status
description: "Show a comprehensive project status dashboard: task queue, blocked items, session state, verification, and git status."
---

# Project Status Dashboard

Gather data from all available sources and present a structured status dashboard.

## Data Collection

Collect the following in parallel where possible:

### 1. Task Queue (MCP tools)
- Call `task_list` to get all tasks with their status, priority, and assignments
- Call `task_get_stats` to get aggregate totals and the next actionable task
- Compute counts by status: `todo`, `analysing`, `analysed`, `in-progress`, `done`, `needs-input`, `skipped`

### 2. Session State (MCP tool)
- Call `session_get_state` to get current session info (if an active session exists)

### 3. Git Status (shell)
- Run `git status --short` to check working tree cleanliness
- Run `git log --oneline -5` to show recent commits
- Run `git branch --show-current` to identify the current branch

### 4. Verification Gates (shell)
- Run `pwsh .bot/hooks/verify/00-privacy-scan.ps1` — privacy/secrets scan
- Run `pwsh .bot/hooks/verify/01-git-clean.ps1` — working tree cleanliness

## Presentation Format

Present results as a structured dashboard:

```
## Task Queue
| Status       | Count |
|--------------|-------|
| todo         | N     |
| analysed     | N     |
| in-progress  | N     |
| done         | N     |
| needs-input  | N     |

## Next Up
<Highest priority task in `todo` or `analysed` status — show ID, title, priority>

## Currently Active
<Any tasks in `analysing` or `in-progress` status — show ID, title, assignee>

## Blocked / Needs Input
<Tasks in `needs-input` status — show ID, title, reason>

## Session
<Active session info, or "No active session">

## Git Status
Branch: <branch>
Clean: <yes/no>
Recent commits:
  <last 5 commits>

## Verification
- Privacy scan: PASS/FAIL
- Git clean: PASS/FAIL

## Suggestions
<Actionable next steps based on the current state, e.g.:
 - "3 tasks are analysed and ready for implementation"
 - "1 task needs input — review task T-XXXXXXXX"
 - "Working tree has uncommitted changes — commit or stash before starting next task">
```

## Rules

- **Read-only**: Do not modify any state, tasks, or files
- **Show all statuses**: Include zero-count rows so the full picture is visible
- **Be honest**: If an MCP tool or hook fails, report the error rather than hiding it
- **Actionable suggestions**: Always end with 1-3 concrete next steps based on what the data shows
