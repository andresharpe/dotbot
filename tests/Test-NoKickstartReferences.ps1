#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Warning gate — flag `kickstart` references outside the allowlist.
.DESCRIPTION
    Tracks the rename from "kickstart" vocabulary to "start-from-*" and
    "workflow-launch-*" (rework roadmap PR-2). Emits warnings, not errors,
    so the gate does not block PR-3 — that PR deletes the remaining
    kickstart engine. PR-6 promotes this to a hard failure once the
    rename is complete and tightens the allowlist.

    Allowlist (paths matched against forward-slash-normalised relative
    paths from the repo root):

      ideas/                                                  historical design notes
      docs/                                                   historical roadmap docs
      specs/                                                  historical specs
      studio-ui/                                              not in scope of this rework
      CHANGELOG.md                                            release-history references
      tests/Test-NoKickstartReferences.ps1                    this file
      tests/Test-KickstartLauncher.ps1                        deleted in PR-3
      workflows/default/systems/runtime/modules/ProcessTypes/Invoke-KickstartProcess.ps1   deleted in PR-3
      workflows/default/systems/ui/modules/ProductAPI.psm1    deleted in PR-3
      workflows/default/systems/ui/server.ps1                 /api/product/kickstart routes, deleted in PR-3
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: No-Kickstart References (warning gate)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$allowlist = @(
    'ideas/',
    'docs/',
    'specs/',
    'studio-ui/',
    'CHANGELOG.md',
    'tests/Test-NoKickstartReferences.ps1',
    'tests/Test-KickstartLauncher.ps1',
    'workflows/default/systems/runtime/modules/ProcessTypes/Invoke-KickstartProcess.ps1',
    'workflows/default/systems/ui/modules/ProductAPI.psm1',
    'workflows/default/systems/ui/server.ps1'
)

# `git grep -nI` is fast, indexed, and ignores binary files.
# Excluding .git is implicit; binary detection covers PNG/PDF/PPTX etc.
Push-Location $repoRoot
try {
    $matches = & git grep -nI 'kickstart' 2>$null
} finally {
    Pop-Location
}

if (-not $matches) {
    Write-TestResult -Name "No kickstart references found anywhere" -Status Pass
    [void](Write-TestSummary -LayerName "Layer 1: No-Kickstart References")
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
    # Warning-only gate until PR-6. Print yellow inline so the developer
    # sees the count and a sample, but record the result as Pass so the
    # suite stays green.
    Write-Host "  ⚠ kickstart references outside allowlist: $($unexpected.Count) (warning, not failure)" -ForegroundColor Yellow
    foreach ($line in ($unexpected | Select-Object -First 30)) {
        Write-Host "      $line" -ForegroundColor DarkYellow
    }
    if ($unexpected.Count -gt 30) {
        Write-Host "      ... and $($unexpected.Count - 30) more" -ForegroundColor DarkYellow
    }
    Write-TestResult -Name "kickstart references outside allowlist (warning gate)" -Status Pass `
        -Message "$($unexpected.Count) outside-allowlist hit(s); promoted to a hard fail in PR-6"
} else {
    Write-TestResult -Name "kickstart references outside allowlist (warning gate)" -Status Pass `
        -Message "All $allowedHits hit(s) are inside the allowlist."
}

[void](Write-TestSummary -LayerName "Layer 1: No-Kickstart References")

# Always exit 0 — warning-only gate until PR-6 promotes it to hard fail.
exit 0
