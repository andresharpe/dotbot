# Implementation Plan Template

> **Purpose**: Detailed code-level implementation plan for a single repository.
> **Repo**: {RepoName}
> **Initiative**: (read from `jira-context.md`)
> **Date**: (current date)
> **Based on**: Deep dive report (`repos/{RepoName}.md`) and implementation research (`04_IMPLEMENTATION_RESEARCH.md`)

---

## 1. Context

Brief summary of:
- What this repo does in the platform
- How the initiative affects it
- Tier and impact rating (from deep dive)
- Reference implementation being followed

---

## 2. Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | | | |

Key architectural and implementation choices. Include alternatives considered and why they were rejected.

---

## 3. Scope

### In Scope

- Files to create
- Files to modify
- Config changes
- Database scripts
- Test additions

### Out of Scope

- What's explicitly NOT included (blocked items, future phases)
- Items deferred to remediation

### Blocked Items

| Item | Blocker | Stub Approach |
|------|---------|---------------|
(work that cannot fully complete — include functional stubs with TODO markers)

---

## 4. Implementation Order

Ordered list of changes within this repo:

1. (First change — typically the foundation: constants, enums, config)
2. (Second change — core domain models/logic)
3. (Third change — integration/transformation)
4. ...
N. (Final change — tests, verification)

Note dependencies between steps.

---

## 5. Detailed Changes

### 5.1 {First File/Component}

**File**: `path/to/file.ext`
**Change type**: Modify / Create / Clone from reference
**Based on**: `path/to/reference/file.ext` (if cloning pattern)

**Changes**:
```
(code snippet showing the specific pattern to follow — not pseudocode, actual syntax from the reference implementation with placeholders for initiative-specific values)
```

**Notes**: (any gotchas, edge cases, or decisions to make during implementation)

### 5.2 {Second File/Component}

(repeat for each file)

---

## 6. Configuration

| Config File | Key/Section | Value | Description |
|-------------|-------------|-------|-------------|

---

## 7. Database Scripts

| # | Script Name | Purpose | Complexity | Depends On |
|---|-------------|---------|------------|------------|

For each script, describe:
- What it creates/modifies
- Naming convention to follow
- Any data dependencies

---

## 8. Unit Tests

| # | Test File | Test Cases | Coverage Target |
|---|-----------|------------|-----------------|

For each test file:
- What it validates
- Test data requirements
- Mocking requirements

---

## 9. Verification

### Build Commands

```bash
(exact commands to build this repo)
```

### Test Commands

```bash
(exact commands to run tests)
```

### Manual Verification Steps

1. (what to check after implementation)
2. (integration points to validate)

---

## 10. Cross-Repo Dependencies

| Direction | Repo | Dependency | Impact |
|-----------|------|------------|--------|
| Upstream | | | Must be implemented first |
| Downstream | | | Can proceed after this repo |

---

## 11. TODO Marker Convention

Use a searchable TODO marker for blocked items:

```
// TODO({initiative-keyword}): description of what's blocked and what's needed
```

Example: `// TODO(provider): Replace stub with actual field mapping once provider spec is available`

This allows easy discovery of all blocked items across the codebase.
