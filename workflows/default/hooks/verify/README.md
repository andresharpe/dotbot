# Verification Scripts

Automated quality checks that run when marking a task as done via `task_mark_done` MCP tool.

## Overview

This directory contains verification scripts that enforce quality standards before allowing tasks to be marked complete. Scripts run automatically - there's no way to skip them.

## How It Works

1. Agent calls `task_mark_done` MCP tool with task ID
2. Tool reads `config.json` to determine which scripts to run
3. Each script executes in order, receiving task metadata
4. Scripts return standardized JSON indicating pass/fail
5. If all required scripts pass → task moves to `done/`
6. If any required script fails → task stays `in-progress`, error details returned to agent

## Script Communication Protocol

All verification scripts **MUST** output JSON to stdout with this structure:

```json
{
  "success": true,
  "script": "script-name.ps1",
  "message": "Human readable summary",
  "details": {
    "key": "value",
    "metrics": 123
  },
  "failures": [
    {
      "file": "src/Component.tsx",
      "line": 42,
      "issue": "Description of problem",
      "severity": "error",
      "snippet": "Code snippet showing issue"
    }
  ],
  "evidence": [
    ".bot/verification/evidence/screenshot.png",
    ".bot/verification/evidence/log.txt"
  ]
}
```

### Required Fields

- **success** (boolean): `true` if verification passed, `false` if failed
- **script** (string): Name of the script file
- **message** (string): Human-readable summary for the agent

### Optional Fields

- **details** (object): Arbitrary key-value pairs with metrics, counts, etc.
- **failures** (array): List of specific issues found
  - **file** (string): Path to file with issue
  - **line** (number): Line number (optional)
  - **issue** (string): Description of the problem
  - **severity** (string): "error" or "warning"
  - **snippet** (string): Code snippet (optional)
- **evidence** (array): Paths to screenshots, logs, or other artifacts

## Configuration

Edit `config.json` to control script execution:

```json
{
  "scripts": [
    {
      "name": "00-pre-flight.ps1",
      "description": "What this script checks",
      "required": true,
      "timeout_seconds": 30,
      "skip_if_category": [],
      "run_if_category": []
    }
  ],
  "continue_on_optional_failure": true,
  "evidence_dir": ".bot/verification/evidence"
}
```

### Script Configuration

- **name**: Script filename
- **description**: Human-readable description
- **required**: If `true`, failure blocks marking done
- **timeout_seconds**: Max execution time
- **skip_if_category**: Array of task categories to skip (e.g., `["infrastructure"]`)
- **run_if_category**: If set, only run for these categories (e.g., `["feature", "ui-ux"]`)

### Task Categories

- `core` - Core functionality
- `feature` - User-facing features (preserved as category name)
- `enhancement` - Improvements to existing features
- `bugfix` - Bug fixes
- `infrastructure` - Backend, database, deployment
- `ui-ux` - Interface and experience improvements

## Script Parameters

All scripts receive these parameters:

```powershell
param(
    [string]$TaskId,       # UUID of the task being verified
    [string]$Category      # Task category (core, feature, etc.)
)
```

Use these to customize behavior:
- Skip certain checks for infrastructure tasks
- Run UI tests only for ui-ux tasks
- Log which task was verified

## Included Scripts

### 00-pre-flight.ps1

Environment and prerequisite checks:
- Verifies git repository
- Checks for uncommitted changes (warning)
- Runs build if applicable (dotnet/nodejs)

**Required**: Yes
**Skip for**: None

### 10-mock-data-scan.ps1

Scans codebase for mock data patterns:
- Variables named `mockData`, `fakeData`, etc.
- TODO/FIXME comments about mock data
- Placeholder text (Lorem ipsum, test emails, etc.)

**Required**: Yes
**Skip for**: infrastructure (database setup may have seed data)

## Adding Custom Scripts

1. **Create script file**: `##-your-script.ps1` (## = execution order)
2. **Accept parameters**: `param([string]$TaskId, [string]$Category)`
3. **Output JSON**: Use the protocol above
4. **Add to config.json**: Register your script
5. **Test**: Try marking a task done

### Example Custom Script

```powershell
# 20-linting.ps1
param(
    [string]$TaskId,
    [string]$Category
)

$issues = @()

# Run ESLint
try {
    $lintOutput = npm run lint 2>&1
    if ($LASTEXITCODE -ne 0) {
        $issues += @{
            issue = "Linting failed"
            severity = "error"
            context = "Run 'npm run lint' to see details"
        }
    }
} catch {
    $issues += @{
        issue = "Could not run linter"
        severity = "error"
    }
}

$output = @{
    success = ($issues.Count -eq 0)
    script = "20-linting.ps1"
    message = if ($issues.Count -eq 0) { "Linting passed" } else { "Linting failed" }
    details = @{ issues_found = $issues.Count }
    failures = $issues
}

$output | ConvertTo-Json -Depth 10
```

## Naming Convention

Use numeric prefixes for execution order:
- `00-##` - Pre-flight checks (environment, build)
- `10-##` - Static analysis (mock data, linting)
- `20-##` - Unit tests
- `30-##` - Integration tests
- `40-##` - E2E/UI tests (Playwright)
- `50-##` - Post-checks (coverage, documentation)

## Debugging

If verification fails:

1. Check the `verification_results` in the MCP tool response
2. Look at `failures` array for specific issues
3. Run the script manually: `.\<script>.ps1 -TaskId "xxx" -Category "feature"`
4. Fix issues and try `task_mark_done` again

## Best Practices

### Do's
✅ Make scripts fast (seconds, not minutes)
✅ Provide actionable error messages
✅ Use severity levels (error vs warning)
✅ Capture evidence (screenshots, logs)
✅ Handle errors gracefully (try/catch)
✅ Skip irrelevant checks by category

### Don'ts
❌ Don't run slow tests in required scripts
❌ Don't fail on warnings
❌ Don't require manual intervention
❌ Don't assume specific tools installed
❌ Don't write to git repository

## Examples

### Check Tests Pass

```powershell
# 30-tests.ps1
param([string]$TaskId, [string]$Category)

$testOutput = dotnet test --no-build 2>&1
$passed = $LASTEXITCODE -eq 0

@{
    success = $passed
    script = "30-tests.ps1"
    message = if ($passed) { "All tests passed" } else { "Tests failed" }
    details = @{ exit_code = $LASTEXITCODE }
    failures = if (-not $passed) {
        @(@{ issue = "Test suite failed"; severity = "error" })
    } else { @() }
} | ConvertTo-Json -Depth 10
```

### Playwright E2E Check

```powershell
# 40-playwright-check.ps1
param([string]$TaskId, [string]$Category)

# Only run for UI tasks
if ($Category -notin @("feature", "ui-ux")) {
    @{
        success = $true
        script = "40-playwright-check.ps1"
        message = "Skipped (not a UI task)"
    } | ConvertTo-Json
    return
}

# Run Playwright tests for this task
$testOutput = npx playwright test --grep "$TaskId" 2>&1
$passed = $LASTEXITCODE -eq 0

@{
    success = $passed
    script = "40-playwright-check.ps1"
    message = if ($passed) { "E2E tests passed" } else { "E2E tests failed" }
    evidence = @("playwright-report/index.html")
    failures = if (-not $passed) {
        @(@{ issue = "Playwright tests failed"; severity = "error" })
    } else { @() }
} | ConvertTo-Json -Depth 10
```

## Troubleshooting

**Script not running:**
- Check it's listed in `config.json`
- Verify filename matches exactly
- Ensure it's in `.bot/verification-scripts/` directory

**Script always fails:**
- Run manually to see full output
- Check script has execute permissions (Unix)
- Verify script outputs valid JSON

**Need to bypass verification:**
- Don't. Fix the issues instead.
- Verification exists to prevent broken tasks.
- If a check is wrong, fix the script or config.

## Integration

These scripts are called automatically by `.bot/mcp/tools/task_mark_done/script.ps1`. No manual invocation needed - just use the `task_mark_done` MCP tool as normal.
