#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Hard gate — fail if `kickstart` appears outside the allowlist.
.DESCRIPTION
    Locks in the rename from "kickstart" vocabulary to "start-from-*" and
    "workflow-launch-*" (rework roadmap PR-2 through PR-6). Fails the build
    on any "kickstart" reference outside historical design notes and this
    file itself.

    Allowlist (paths matched against forward-slash-normalised relative
    paths from the repo root):

      ideas/                                  historical design notes
      tests/Test-NoLegacyVocabulary.ps1       this file
      CHANGELOG.md                            documents the rename itself
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: No Legacy Vocabulary (hard fail)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$allowlist = @(
    'ideas/',
    'tests/Test-NoLegacyVocabulary.ps1',
    'CHANGELOG.md'
)

# `git grep -nI` is fast, indexed, and ignores binary files.
# Excluding .git is implicit; binary detection covers PNG/PDF/PPTX etc.
Push-Location $repoRoot
try {
    $matches = & git grep -nIi 'kickstart' 2>$null
} finally {
    Pop-Location
}

if (-not $matches) {
    Write-TestResult -Name "No kickstart references found anywhere" -Status Pass
    [void](Write-TestSummary -LayerName "Layer 1: No Legacy Vocabulary")
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
    # Hard fail. Print red inline so the developer sees the count and a
    # sample, then record the failure and exit non-zero.
    Write-Host "  ✗ kickstart references outside allowlist: $($unexpected.Count)" -ForegroundColor Red
    foreach ($line in ($unexpected | Select-Object -First 30)) {
        Write-Host "      $line" -ForegroundColor DarkRed
    }
    if ($unexpected.Count -gt 30) {
        Write-Host "      ... and $($unexpected.Count - 30) more" -ForegroundColor DarkRed
    }
    Write-TestResult -Name "kickstart references outside allowlist" -Status Fail `
        -Message "$($unexpected.Count) outside-allowlist hit(s); allowlist is ideas/, this file, and CHANGELOG.md"
    [void](Write-TestSummary -LayerName "Layer 1: No Legacy Vocabulary")
    exit 1
}

Write-TestResult -Name "kickstart references outside allowlist" -Status Pass `
    -Message "All $allowedHits hit(s) are inside the allowlist."
[void](Write-TestSummary -LayerName "Layer 1: No Legacy Vocabulary")
exit 0
