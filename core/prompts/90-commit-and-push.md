---
name: Commit and Push
description: Organize changes into logical commits and push
version: 1.1
---

# Commit and Push

Organize uncommitted changes into clean, atomic commits with meaningful messages.

---

## Protocol

### 1. Analyze

```bash
git --no-pager status --short
git --no-pager diff [files]
```

Status markers: `M` modified, `??` untracked, `D` deleted, `A` added

**Use `git add -A`** to stage all changes including deletions.

### 2. Group by Topic

**Group by**: feature, bug, layer, component, or concern

**Do**:
- Related changes together
- Tests with their code
- Config separate from logic

**Don't**:
- Mix unrelated changes
- Mix formatting with logic
- Include generated files with source

### 3. Commit Each Group

```bash
git add [files]
git commit -m "type: subject

- Detail 1
- Detail 2"
```

### 4. Push

```bash
git push
```

If rejected: `git pull --rebase && git push`

### 5. Verify

```bash
git status --short
```

Must be empty. If files remain, repeat from step 1.

---

> **⚠️** Task completion moves files between directories. Use `git add -A` (not `git add .`) to capture deletions.

---

## Commit Message Format

```
<type>: <subject>

<body>

<footer>
```

### Types

| Type | Use for |
|------|--------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructure (no behavior change) |
| `perf` | Performance improvement |
| `test` | Adding/updating tests |
| `chore` | Build, tools, dependencies |
| `style` | Formatting (no code change) |
| `ci` | CI/CD changes |

### Subject Line

- Imperative mood: "add" not "added"
- Lowercase (unless proper noun)
- No period
- Under 72 chars

### Body (optional)

- What and why, not how
- Bullet points for multiple items
- Wrap at 72 chars

### Footer (optional)

- `Fixes #123`
- `BREAKING CHANGE: description`

---

## Examples

**Simple fix**:
```
fix: normalize path separators in log output
```

**Feature with details**:
```
feat: add auth checks to sync handlers

- Check auth before email/calendar sync
- Skip gracefully when not authenticated
- Add staleness warning to briefing commands
```

**Refactor with context**:
```
refactor: extract validation into separate service

Reduces complexity in the main handler and allows
for easier testing of validation logic.
```

---

## Grouping Decisions

**Split** when changes:
- Solve different problems
- Could be reverted independently
- Affect different subsystems

**Combine** when changes:
- Are part of same fix/feature
- Can't work independently
- Are test + code for same functionality

---

## Quick Reference

| Task | Command |
|------|--------|
| Reorder commits | `git rebase -i HEAD~n` |
| Squash commits | `git rebase -i HEAD~n` (mark with `s`) |
| Split last commit | `git reset HEAD~1` then re-commit |
| Undo unpushed | `git reset HEAD~1` |
| Undo pushed | `git reset --hard HEAD~1 && git push -f` |
