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

$modulePath = Join-Path $PSScriptRoot ".." ".." "systems" "mcp" "modules" "FrameworkIntegrity.psm1"
if (-not (Test-Path -LiteralPath $modulePath)) {
    # Fall back to project root (anchored via git) when invoked outside the
    # MCP server context — CWD may not be the project root.
    $root = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($root) {
        $modulePath = Join-Path $root ".bot/systems/mcp/modules/FrameworkIntegrity.psm1"
    }
}
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
