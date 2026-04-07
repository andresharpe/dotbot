#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test runner for dotbot integration test suite.
.DESCRIPTION
    Orchestrates test layers 1-4. Use -Layer to select which layers to run.
.PARAMETER Layer
    Which layer(s) to run: 1, 2, 3, 4, or 'all' (default: 'all' runs 1-3; use 4 explicitly)
.EXAMPLE
    ./Run-Tests.ps1                # Runs layers 1-3
    ./Run-Tests.ps1 -Layer 1       # Runs layer 1 only
    ./Run-Tests.ps1 -Layer all     # Runs layers 1-3
    ./Run-Tests.ps1 -Layer 4       # Runs layer 4 only (requires Claude credentials)
    ./Run-Tests.ps1 -Layer 1,2,3,4 # Runs all layers including E2E
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Layer = @('all')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  dotbot Integration Test Suite" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

# Determine which layers to run
$layersToRun = @()
foreach ($l in $Layer) {
    switch ($l) {
        'all'  { $layersToRun += @(1, 2, 3) }
        '1'    { $layersToRun += 1 }
        '2'    { $layersToRun += 2 }
        '3'    { $layersToRun += 3 }
        '4'    { $layersToRun += 4 }
        default {
            Write-Host "  Unknown layer: $l" -ForegroundColor Red
            Write-Host "  Valid values: 1, 2, 3, 4, all" -ForegroundColor Yellow
            exit 1
        }
    }
}
$layersToRun = $layersToRun | Sort-Object -Unique

$layerNames = $layersToRun | ForEach-Object { "Layer $_" }
Write-Host "  Running: $($layerNames -join ', ')" -ForegroundColor Cyan
Write-Host ""

# ── Stale install detection ──────────────────────────────────────────────
# Layer 2+ tests create projects via init-project.ps1 which copies from
# the installed dotbot (~\dotbot). If the dev source is newer, tests will
# run against stale code and produce confusing failures.
$devDir = Split-Path $PSScriptRoot -Parent  # repo root
$installDir = Join-Path $HOME "dotbot"
if ((Test-Path $installDir) -and (2 -in $layersToRun -or 3 -in $layersToRun -or 4 -in $layersToRun)) {
    $devNewest = (Get-ChildItem "$devDir\workflows","$devDir\stacks" -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $installNewest = (Get-ChildItem "$installDir\workflows","$installDir\stacks" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($devNewest -gt $installNewest) {
        Write-Host "  ⚠ Installed dotbot is stale (dev source is newer)" -ForegroundColor Yellow
        Write-Host "  → Auto-installing from dev source..." -ForegroundColor Yellow
        & pwsh -NoProfile -File "$devDir\install.ps1" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Installed" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Install failed — tests may use stale code" -ForegroundColor Red
        }
        Write-Host ""
    }
}

$overallFailed = $false
$layerResults = @{}

# Layer 1: Structure + Compilation
if (1 -in $layersToRun) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-Structure.ps1"
    $structureCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-Compilation.ps1"
    $compilationCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-WorkflowManifest.ps1"
    $workflowManifestCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-MdRefs.ps1"
    $mdRefsCode = $LASTEXITCODE

    $exitCode = if ($structureCode -ne 0 -or $compilationCode -ne 0 -or $workflowManifestCode -ne 0 -or $mdRefsCode -ne 0) { 1 } else { 0 }
    $layerResults["1"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}

# Layer 2: Components
if (2 -in $layersToRun) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-Components.ps1"
    $componentsCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-TaskActions.ps1"
    $taskActionsCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-ServerStartup.ps1"
    $serverStartupCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-WorkflowIntegration.ps1"
    $workflowIntegrationCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-ProcessRegistry.ps1"
    $processRegistryCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-ProcessDispatch.ps1"
    $processDispatchCode = $LASTEXITCODE

    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-StudioAPI.ps1"
    $studioAPICode = $LASTEXITCODE

    $exitCode = if ($componentsCode -ne 0 -or $taskActionsCode -ne 0 -or $serverStartupCode -ne 0 -or $workflowIntegrationCode -ne 0 -or $processRegistryCode -ne 0 -or $processDispatchCode -ne 0 -or $studioAPICode -ne 0) { 1 } else { 0 }
    $layerResults["2"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}
# Layer 3: Mock Claude
if (3 -in $layersToRun) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-MockClaude.ps1"
    $exitCode = $LASTEXITCODE
    $layerResults["3"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}

# Layer 4: E2E Claude
if (4 -in $layersToRun) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-E2E-Claude.ps1"
    $exitCode = $LASTEXITCODE
    $layerResults["4"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}

# Overall summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  Overall Results" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""

foreach ($layer in $layersToRun) {
    $key = "$layer"
    $status = if ($layerResults[$key]) { "✓ PASSED" } else { "✗ FAILED" }
    $color = if ($layerResults[$key]) { "Green" } else { "Red" }
    Write-Host "  Layer $layer : $status" -ForegroundColor $color
}

Write-Host ""

if ($overallFailed) {
    Write-Host "  RESULT: FAILED" -ForegroundColor Red
    Write-Host ""
    exit 1
} else {
    Write-Host "  RESULT: ALL PASSED" -ForegroundColor Green
    Write-Host ""
    exit 0
}

