---
name: verify
description: "Run all verification gates (privacy scan, git cleanliness, git pushed) and report results."
---

# Run Verification Gates

Run all verification hooks in `.bot/hooks/verify/` and present a clear pass/fail report.

## Steps

### 1. Privacy Scan
Run the privacy/secrets scanner:
```bash
pwsh .bot/hooks/verify/00-privacy-scan.ps1
```
If the user said `/verify staged` or mentioned "staged only", add the `-StagedOnly` flag:
```bash
pwsh .bot/hooks/verify/00-privacy-scan.ps1 -StagedOnly
```

### 2. Git Clean Check
Check for uncommitted changes outside `.bot/`:
```bash
pwsh .bot/hooks/verify/01-git-clean.ps1
```

### 3. Git Pushed Check
Check for unpushed commits:
```bash
pwsh .bot/hooks/verify/02-git-pushed.ps1
```

## Presentation Format

Present results as a verification report:

```
## Verification Report

| Gate           | Result |
|----------------|--------|
| Privacy scan   | PASS/FAIL |
| Git clean      | PASS/FAIL |
| Git pushed     | PASS/FAIL |

Overall: ALL PASSED / N FAILED

### Failures (if any)

#### <Gate name>
- Issue: <description>
- Remediation: <what to do>
```

## Rules

- **Read-only**: Never fix issues automatically — only report them with remediation guidance
- **Always run all gates**: Do not stop on first failure; run every gate and report all results
- **Report honestly**: Show exact output from each hook; do not summarize away important details
- **Exit code awareness**: Each hook outputs JSON to stdout with `issues` and `details` keys — parse these for structured reporting
- **Remediation guidance**: For each failure, provide a concrete command or action the user can take to resolve it
