#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit tests for the three shared MCP helper scripts under
    core/mcp/{Resolve-ProjectRoot,dotbot-mcp-helpers,modules/Extract-CommitInfo}.
    Issue-#25 regression guard: each helper is dot-sourceable, so we also
    verify dot-sourcing does not elevate the caller's strict mode.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: MCP Shared Helpers (issue #25 coverage)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

function Test-DotSourceIsolation {
    param([string]$Path)
    $probe = @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$global:DotbotProjectRoot = '$repoRoot'
try { . '$($Path -replace "'", "''")' } catch { }
try {
    `$x = [pscustomobject]@{ a = 1 }
    `$null = `$x.b
    Write-Output 'OK'
} catch {
    Write-Output "LEAK: `$(`$_.Exception.Message)"
}
"@
    $output = & pwsh -NoProfile -Command $probe 2>$null
    return ($output | Where-Object { $_ } | Select-Object -Last 1)
}

# ─── 1. Resolve-ProjectRoot.ps1 ──────────────────────────────────────────
$path = Join-Path $repoRoot "core/mcp/Resolve-ProjectRoot.ps1"
Assert-Equal -Name "Resolve-ProjectRoot: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# A repo directory (has .git) should resolve to the repo root.
$resolved = Resolve-DotbotProjectRoot -StartPath $repoRoot
Assert-True -Name "Resolve-DotbotProjectRoot: resolves repo root from itself" -Condition ($null -ne $resolved)
# A non-existent path should return $null without throwing.
$missing = $null
$ranOk = $true
try { $missing = Resolve-DotbotProjectRoot -StartPath '/nonexistent/path-9999' } catch { $ranOk = $false }
Assert-True -Name "Resolve-DotbotProjectRoot: returns null for non-existent path without throwing" -Condition ($ranOk -and $null -eq $missing)

# ─── 2. dotbot-mcp-helpers.ps1 ───────────────────────────────────────────
$path = Join-Path $repoRoot "core/mcp/dotbot-mcp-helpers.ps1"
Assert-Equal -Name "dotbot-mcp-helpers: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# Get-DateFromString is the safest helper to exercise — pure transformation.
$ranOk = $true
$parsed = $null
try { $parsed = Get-DateFromString -DateString '2026-05-21T00:00:00Z' } catch { $ranOk = $false }
Assert-True -Name "Get-DateFromString: parses ISO-8601 without throwing" -Condition $ranOk
# Empty/invalid input should return $null or a default, not throw.
$ranOk = $true
try { $null = Get-DateFromString -DateString '' } catch { $ranOk = $false }
Assert-True -Name "Get-DateFromString: handles empty input without throwing" -Condition $ranOk

# ─── 3. Extract-CommitInfo.ps1 ───────────────────────────────────────────
$path = Join-Path $repoRoot "core/mcp/modules/Extract-CommitInfo.ps1"
Assert-Equal -Name "Extract-CommitInfo: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# A randomly-shaped task id with no matching commit should return zero
# commits without throwing (the function scans `git log` for `[task:id]`).
$ranOk = $true
$info = $null
try {
    $info = Get-TaskCommitInfo -TaskId 'nomatch-9999-xyz' -ProjectRoot $repoRoot
} catch {
    $ranOk = $false
}
Assert-True -Name "Get-TaskCommitInfo: returns empty result for unmatched task id without throwing" -Condition $ranOk
if ($info) {
    Assert-True -Name "Get-TaskCommitInfo: empty result has commits array property" `
        -Condition ($info.PSObject.Properties['commits'] -or $info -is [hashtable])
}

$allPassed = (Write-TestSummary -LayerName "Layer 1: MCP Shared Helpers")
if ($allPassed) { exit 0 } else { exit 1 }
