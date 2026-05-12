# Implementation Remediation Template

> **Purpose**: Record of build/test fixes applied after initial implementation.
> **Repo**: {RepoName}
> **Initiative**: (read from `jira-context.md`)
> **Date**: (current date)
> **Outcomes**: `{RepoName}_Outcomes.md`

---

## 1. Environment Setup Issues

Document any environment or authentication issues encountered:

| # | Issue | Cause | Resolution |
|---|-------|-------|------------|
| 1 | | | |

Common issues:
- NuGet feed authentication (PAT expired, missing env var)
- VPN/network access to private feeds
- SDK version mismatches
- Missing tools or dependencies

---

## 2. Compilation Errors Fixed

| # | File | Error | Cause | Fix |
|---|------|-------|-------|-----|
| 1 | | | | |

For each error:
- Exact error message (or key portion)
- Root cause analysis
- Fix applied
- Whether the fix was in new code or required changes to existing code

---

## 3. Test Failures Resolved

| # | Test File | Test Name | Failure | Fix |
|---|-----------|-----------|---------|-----|
| 1 | | | | |

For each failure:
- The assertion or exception that failed
- Root cause
- Fix applied

---

## 4. Final Build and Test Status

| Repo | Build | Unit Tests | Integration Tests | Notes |
|------|-------|------------|-------------------|-------|
| {RepoName} | Pass / Fail | N/N pass | N/A / N/N pass | |

---

## 5. Files Modified During Remediation

| # | File | Change Description | Original Error |
|---|------|--------------------|----------------|
| 1 | | | |

---

## 6. Developer Notes

Lessons learned and gotchas for future reference:

### Authentication Quick Reference

(document any auth setup steps that were non-obvious)

### Build Quirks

(document any repo-specific build issues — e.g., SSDT projects, specific build order requirements)

### Known Pre-Existing Issues

(issues that existed before this implementation — document so they aren't confused with initiative changes)

### Pending Design Decisions

(decisions deferred during remediation that need stakeholder input)
