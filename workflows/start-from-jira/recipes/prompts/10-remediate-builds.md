---
name: Remediate Builds
description: Compile and test each repo, fix errors, commit fixes to initiative branch, produce remediation reports
version: 1.0
---

# Remediate Builds

After implementation, systematically compile and test each affected repo. Fix all errors. All remediation fixes are committed to the same `initiative/{JIRA_KEY}` branch.

## Prerequisites

- Implementation must be complete — `{RepoName}_Outcomes.md` must exist for target repos
- Repos must be cloned with initiative branch checked out
- `.env.local` must have valid credentials (NuGet PAT, ADO PAT)

## Your Task

### Step 1: Read Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
```

Check repo status:
```
mcp__dotbot__repo_list({})
```

Identify repos with `status: "implemented"` — these need remediation.

### Step 1.5: Check Baseline Build State

Read the implementation plan for each repo:
```
Read({ file_path: "repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md" })
```

If the analysis captured a `baseline_build` with pre-existing errors:
- **Do NOT fix pre-existing errors** — only fix errors introduced by initiative changes
- Document pre-existing errors in the remediation report under "Pre-existing Issues (Not Fixed)"
- Compare current error list against baseline to identify which are new

### Step 2: For Each Repo — Build

**2a. Set up environment:**

Load `.env.local` credentials. For .NET repos, ensure NuGet authentication:

```powershell
$nugetVarName = $env:NUGET_FEED_VAR
if ($nugetVarName) {
    # Try Machine-level var first (corporate workstation setup)
    $nugetPat = [System.Environment]::GetEnvironmentVariable($nugetVarName, "Machine")

    # Fall back to .env.local value
    if (-not $nugetPat) { $nugetPat = $env:NUGET_FEED_PAT }

    # Fall back to ADO PAT
    if (-not $nugetPat) { $nugetPat = $env:AZURE_DEVOPS_PAT }

    if ($nugetPat) {
        [System.Environment]::SetEnvironmentVariable($nugetVarName, $nugetPat, "Process")
    }
}
```

**2b. Restore and build:**

```bash
cd repos/{RepoName}

# .NET repos (reads NuGet env var name from NUGET_FEED_VAR):
pwsh -Command "
    \$varName = \$env:NUGET_FEED_VAR
    if (\$varName) {
        [System.Environment]::SetEnvironmentVariable(\$varName, \$env:NUGET_FEED_PAT, 'Process')
    }
    dotnet restore src/{Solution}.sln --configfile src/NuGet.config
    dotnet build src/{Solution}.sln
"

# Node repos:
npm install && npm run build

# Other: follow build commands from the implementation plan
```

**2c. Record results:**
- If build succeeds: note "Build: PASS"
- If build fails: capture error messages, diagnose, fix

### Step 3: For Each Repo — Fix Compilation Errors

For each compilation error:

1. **Read the error message** — identify file, line, and error code
2. **Diagnose the cause** — missing using/import, wrong type, missing property, etc.
3. **Fix the error** — apply the minimal correct fix
4. **Re-build** — verify the fix resolves the error without introducing new ones
5. **Document** — record the error, cause, and fix in the remediation report

Common patterns:
- Missing `using` statements for new types
- Property name mismatches between models
- Mock verification failures for changed method signatures
- NuGet feed authentication issues
- **File lock errors on Windows** — If a build fails with an IO/access/lock error, retry once before diagnosing code issues. Antivirus real-time scanning can temporarily lock files during compilation.

### Step 4: For Each Repo — Run Tests

```bash
# .NET repos:
pwsh -Command "dotnet test src/{TestProject}.csproj --no-build"

# Node repos:
npm test
```

Fix any test failures following the same diagnose-fix-document cycle.

### Step 5: Commit Fixes

```bash
cd repos/{RepoName}
git add -A
git commit -m "Fix build and test issues

[{JIRA_KEY}] Remediation
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Step 6: Write Remediation Report

Using the remediation template (`prompts/implementation/remediation.md`), write:
```
repos/{RepoName}/.bot/workspace/product/{RepoName}_Remediation.md
```

Document:
1. Environment setup issues and resolutions
2. Each compilation error: file, error, cause, fix
3. Each test failure: test, failure, cause, fix
4. Final build and test status
5. Files modified during remediation
6. Developer notes (auth setup, build quirks, known pre-existing issues)

## Output

Per repo:
- Build and test fixes committed to `initiative/{JIRA_KEY}` branch
- `repos/{RepoName}/.bot/workspace/product/{RepoName}_Remediation.md`

## Critical Rules

- Fix ALL compilation errors — don't leave broken builds
- Fix ALL test failures that are related to the initiative changes
- Document pre-existing test failures separately (don't try to fix them)
- Commit fixes to the same initiative branch — no new branches
- The remediation report is mandatory even if zero fixes were needed
- NuGet auth issues are common — check env vars before diagnosing code issues
- Do NOT push branches — that's Phase 7 (handoff)
