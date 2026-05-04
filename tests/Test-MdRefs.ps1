#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Markdown reference validation tests.
.DESCRIPTION
    Tests the 03-check-md-refs.ps1 verification script to ensure it correctly
    validates .bot/recipes/ path references against the source tree.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot
$scriptPath = Join-Path $repoRoot "core/hooks/verify/03-check-md-refs.ps1"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Markdown Reference Validation Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# SCRIPT EXISTENCE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SCRIPT EXISTENCE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-PathExists -Name "03-check-md-refs.ps1 exists" -Path $scriptPath

# ═══════════════════════════════════════════════════════════════════
# FULL SCAN — INTEGRATION TEST
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  FULL SCAN — INTEGRATION TEST" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$resultJson = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "& '$scriptPath' -RepoRoot '$repoRoot'" 2>$null
$result = $resultJson | ConvertFrom-Json

Assert-True -Name "Script returns valid JSON with success field" `
    -Condition ($null -ne $result -and $null -ne $result.success)

Assert-True -Name "Script returns script field" `
    -Condition ($result.script -eq "03-check-md-refs.ps1")

Assert-True -Name "Script returns details with files_scanned" `
    -Condition ($result.details.files_scanned -gt 0)

Assert-True -Name "Script returns details with references_found" `
    -Condition ($result.details.references_found -gt 0)

Assert-True -Name "Current repo has zero broken references" `
    -Condition ($result.success -eq $true)

if (-not $result.success) {
    foreach ($f in $result.failures) {
        Write-Host "     BROKEN: $($f.file):$($f.line) — $($f.reference)" -ForegroundColor Red
        if ($f.suggestion) { Write-Host "       Suggestion: $($f.suggestion)" -ForegroundColor Yellow }
    }
}

# ═══════════════════════════════════════════════════════════════════
# SKIP PATTERN TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  SKIP PATTERN TESTS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Skipped reference counter is reported" `
    -Condition ($null -ne $result.details.references_skipped -and $result.details.references_skipped -ge 0)

# ═══════════════════════════════════════════════════════════════════
# REFERENCE RESOLUTION TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  REFERENCE RESOLUTION TESTS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Valid references were found (valid count > 0)" `
    -Condition ($result.details.references_valid -gt 0)

Assert-True -Name "No broken references (broken count = 0)" `
    -Condition ($result.details.references_broken -eq 0)

# ═══════════════════════════════════════════════════════════════════
# CONFIG REGISTRATION
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  CONFIG REGISTRATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$configPath = Join-Path $repoRoot "core/hooks/verify/config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$mdRefEntry = $config.scripts | Where-Object { $_.name -eq "03-check-md-refs.ps1" }

Assert-True -Name "03-check-md-refs.ps1 registered in config.json" `
    -Condition ($null -ne $mdRefEntry)

Assert-True -Name "03-check-md-refs.ps1 marked as core" `
    -Condition ($mdRefEntry.core -eq $true)

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
$allPassed = Write-TestSummary -LayerName "Layer 1: Markdown Reference Validation"
if (-not $allPassed) { exit 1 }
