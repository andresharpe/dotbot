#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Hard gate — fail if `Join-Path X "...\..."` patterns appear outside the allowlist.
.DESCRIPTION
    PowerShell on Linux/macOS treats `\` as a literal character in path
    strings, so `Join-Path $x "workspace\tasks"` produces nonexistent paths
    like `/home/user/workspace\tasks` on Unix. Test-Path returns false against
    those paths and surrounding code silently takes the "directory doesn't
    exist" branch — runtime is broken in ways the cross-platform test suite
    cannot catch.

    This test fails the build on any new violation. The fix pattern is a
    forward-slash literal (`"workspace/tasks"`); for interpolated variables
    that may contain `\`, normalise first via `-replace '\\', '/'` (canonical
    example: `core/runtime/modules/post-script-runner.ps1`).

    Allowlist (paths matched against forward-slash-normalised relative paths
    from the repo root):

      tests/                                 test fixtures intentionally use Windows-style strings
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: No Backslash Paths in Join-Path (hard fail)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$allowlist = @(
    'tests/'
)

# Two regexes catch both double- and single-quoted second-arg literals
# containing a backslash. `git grep -nIE` is fast and ignores binaries.
$patterns = @(
    'Join-Path[^"]*"[^"]*\\',
    "Join-Path[^']*'[^']*\\"
)

Push-Location $repoRoot
try {
    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $patterns) {
        $hits = & git grep -nIE -e $pattern -- '*.ps1' '*.psm1' 2>$null
        if ($hits) { foreach ($h in $hits) { [void]$matches.Add($h) } }
    }
} finally {
    Pop-Location
}

if ($matches.Count -eq 0) {
    Write-TestResult -Name "No Join-Path backslash literals found anywhere" -Status Pass
    [void](Write-TestSummary -LayerName "Layer 1: No Backslash Paths")
    exit 0
}

$unexpected = New-Object System.Collections.Generic.List[string]
$allowedHits = 0

foreach ($line in $matches) {
    if ($line -notmatch '^([^:]+):') { continue }
    $file = ($Matches[1] -replace '\\', '/')
    $allowed = $false
    foreach ($prefix in $allowlist) {
        if ($file -eq $prefix -or $file.StartsWith($prefix)) { $allowed = $true; break }
    }
    if ($allowed) {
        $allowedHits++
    } else {
        $unexpected.Add($line)
    }
}

if ($unexpected.Count -gt 0) {
    Write-Host "  ✗ Join-Path backslash literals outside allowlist: $($unexpected.Count)" -ForegroundColor Red
    foreach ($line in ($unexpected | Select-Object -First 30)) {
        Write-Host "      $line" -ForegroundColor DarkRed
    }
    if ($unexpected.Count -gt 30) {
        Write-Host "      ... and $($unexpected.Count - 30) more" -ForegroundColor DarkRed
    }
    Write-Host ""
    Write-Host "  Fix: replace `\` with `/` inside the second argument of Join-Path." -ForegroundColor Yellow
    Write-Host "       Windows accepts both; Linux/macOS only accept forward slashes." -ForegroundColor Yellow
    Write-Host "       For interpolated variables that may contain \, normalise first:" -ForegroundColor Yellow
    Write-Host "         `$normalized = `$x -replace '\\', '/'" -ForegroundColor DarkGray
    Write-Host "         Join-Path `$BotRoot `"systems/runtime/`$normalized`"" -ForegroundColor DarkGray
    Write-TestResult -Name "Join-Path backslash literals outside allowlist" -Status Fail `
        -Message "$($unexpected.Count) outside-allowlist hit(s); see message above for fix pattern."
    [void](Write-TestSummary -LayerName "Layer 1: No Backslash Paths")
    exit 1
}

Write-TestResult -Name "Join-Path backslash literals outside allowlist" -Status Pass `
    -Message "All $allowedHits hit(s) are inside the allowlist."
[void](Write-TestSummary -LayerName "Layer 1: No Backslash Paths")
exit 0
