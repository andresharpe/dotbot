# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
param(
    [string]$TaskId,
    [string]$Category
)

# Framework integrity verify hook.
# Detects modifications to .bot/ files that should only change via
# `dotbot init --force`. Combines a SHA256 manifest check (catches
# `git commit --no-verify` bypasses) with a git-status check (catches
# uncommitted edits). If .bot/ is gitignored, reports that as a failure
# rather than silently passing.

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

$frameworkRoot = Join-Path $PSScriptRoot ".." ".."
$dotbotCorePath = Resolve-FirstExistingPath @(
    (Join-Path $frameworkRoot "runtime" "modules" "DotbotCore.psm1"),
    (Join-Path $frameworkRoot "core" "runtime" "modules" "DotbotCore.psm1")
)
if ($dotbotCorePath) {
    Import-Module $dotbotCorePath -Force -DisableNameChecking
}

$modulePath = Resolve-FirstExistingPath @(
    (Join-Path $frameworkRoot "mcp" "modules" "FrameworkIntegrity.psm1"),
    (Join-Path $frameworkRoot "core" "mcp" "modules" "FrameworkIntegrity.psm1")
)
if (-not $modulePath) {
    $root = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($root) {
        $modulePath = Resolve-FirstExistingPath @(
            (Join-Path $root ".bot" "core" "mcp" "modules" "FrameworkIntegrity.psm1"),
            (Join-Path $root "core" "mcp" "modules" "FrameworkIntegrity.psm1")
        )
    }
}
if (-not $modulePath) { throw "FrameworkIntegrity.psm1 not found" }
Import-Module $modulePath -Force

$result = Test-FrameworkIntegrity

$failures = @()
if (-not $result.success) {
    foreach ($path in $result.files) {
        $failures += @{
            file     = $path
            issue    = "Framework file modified outside 'dotbot init --force'"
            severity = "error"
            snippet  = $path
        }
    }
    if ($failures.Count -eq 0 -and $result.remediation) {
        # Non-tamper failure (gitignored, missing-manifest, git-error): record
        # the reason as a single entry so callers see remediation text.
        $failures += @{
            issue    = $result.message
            severity = "error"
            context  = $result.remediation
        }
    }
}

@{
    success  = $result.success
    script   = "04-framework-integrity.ps1"
    message  = $result.message
    details  = @{
        reason       = $result.reason
        files_checked = (Get-FrameworkProtectedPaths).Count
        tampered     = $failures.Count
        remediation  = $result.remediation
    }
    failures = $failures
} | ConvertTo-Json -Depth 10
