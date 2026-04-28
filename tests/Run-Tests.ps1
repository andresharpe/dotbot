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
    # scripts/ is included so changes to init-project.ps1 / Platform-Functions.psm1
    # / etc. trigger an auto-reinstall (and downstream golden rebuild).
    $devNewest = (Get-ChildItem "$devDir/core","$devDir/workflows","$devDir/stacks","$devDir/scripts" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $installNewest = (Get-ChildItem "$installDir/core","$installDir/workflows","$installDir/stacks","$installDir/scripts" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
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

# ── Golden snapshot fixtures ─────────────────────────────────────────────
# Most Layer 2+ tests just need a ready .bot/, not a fresh init. We build
# .bot/ once per workflow flavor here and tests clone the matching golden
# instead of paying the 30s init cost per section.
if (2 -in $layersToRun -or 3 -in $layersToRun) {
    if (-not (Test-Path $installDir)) {
        Write-Host "  ✗ dotbot is not installed at $installDir" -ForegroundColor Red
        Write-Host "  → Run: pwsh install.ps1" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Import-Module "$PSScriptRoot\Test-Helpers.psm1" -DisableNameChecking
    try {
        Initialize-GoldenSnapshots -Flavors @('start-from-prompt', 'start-from-jira', 'start-from-pr', 'start-from-repo') | Out-Null
        Write-Host ""
    } catch {
        # Layer 2/3 hard-depends on goldens. Continuing would only produce
        # noisy downstream failures, so fail fast here.
        Write-Host "  ✗ Golden snapshot build failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        exit 1
    }
}

$overallFailed = $false
$layerResults = @{}
$layerTimings = @{}

function Invoke-TestFile {
    param(
        [Parameter(Mandatory)][string]$Layer,
        [Parameter(Mandatory)][string]$FileName
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Pipe to Out-Host so the child's stdout goes to the terminal / CI log
    # directly. Without this, the function's success stream captures every
    # line into the caller's `$code = Invoke-TestFile ...` assignment, which
    # both swallows the test output and turns $code into an Object[] instead
    # of an int.
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\$FileName" | Out-Host
    $code = $LASTEXITCODE
    $sw.Stop()

    if (-not $layerTimings.ContainsKey($Layer)) { $layerTimings[$Layer] = @() }
    $layerTimings[$Layer] += [pscustomobject]@{
        File      = $FileName
        ElapsedMs = $sw.ElapsedMilliseconds
        ExitCode  = $code
    }

    return $code
}

function Format-Duration {
    param([int64]$Ms)
    $duration = [TimeSpan]::FromMilliseconds($Ms)
    if ($duration.TotalSeconds -lt 60) {
        return ("{0}s" -f [math]::Round($duration.TotalSeconds, 1))
    }
    $totalSeconds = [int64][math]::Round($duration.TotalSeconds)
    $minutes = [int64]($totalSeconds / 60)
    $seconds = $totalSeconds % 60
    return ("{0}m {1}s" -f $minutes, $seconds)
}

# Layer 1: Structure + Compilation
if (1 -in $layersToRun) {
    $structureCode       = Invoke-TestFile -Layer '1' -FileName 'Test-Structure.ps1'
    $compilationCode     = Invoke-TestFile -Layer '1' -FileName 'Test-Compilation.ps1'
    $workflowManifestCode = Invoke-TestFile -Layer '1' -FileName 'Test-WorkflowManifest.ps1'
    $mdRefsCode          = Invoke-TestFile -Layer '1' -FileName 'Test-MdRefs.ps1'
    $skillCodeReviewCode = Invoke-TestFile -Layer '1' -FileName 'Test-SkillCodeReview.ps1'
    $legacyVocabularyCode = Invoke-TestFile -Layer '1' -FileName 'Test-NoLegacyVocabulary.ps1'
    $activityLogCode     = Invoke-TestFile -Layer '1' -FileName 'Test-ActivityLogHygiene.ps1'

    $exitCode = if ($structureCode -ne 0 -or $compilationCode -ne 0 -or $workflowManifestCode -ne 0 -or $mdRefsCode -ne 0 -or $skillCodeReviewCode -ne 0 -or $legacyVocabularyCode -ne 0 -or $activityLogCode -ne 0) { 1 } else { 0 }
    $layerResults["1"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}

# Layer 2: Components
if (2 -in $layersToRun) {
    $componentsCode          = Invoke-TestFile -Layer '2' -FileName 'Test-Components.ps1'
    $taskActionsCode         = Invoke-TestFile -Layer '2' -FileName 'Test-TaskActions.ps1'
    $serverStartupCode       = Invoke-TestFile -Layer '2' -FileName 'Test-ServerStartup.ps1'
    $workflowIntegrationCode = Invoke-TestFile -Layer '2' -FileName 'Test-WorkflowIntegration.ps1'
    $processRegistryCode     = Invoke-TestFile -Layer '2' -FileName 'Test-ProcessRegistry.ps1'
    $processDispatchCode     = Invoke-TestFile -Layer '2' -FileName 'Test-ProcessDispatch.ps1'
    $studioAPICode           = Invoke-TestFile -Layer '2' -FileName 'Test-StudioAPI.ps1'
    $goScriptCode            = Invoke-TestFile -Layer '2' -FileName 'Test-GoScript.ps1'
    $toolLocalCode           = Invoke-TestFile -Layer '2' -FileName 'Test-ToolLocal.ps1'

    $exitCode = if ($componentsCode -ne 0 -or $taskActionsCode -ne 0 -or $serverStartupCode -ne 0 -or $workflowIntegrationCode -ne 0 -or $processRegistryCode -ne 0 -or $processDispatchCode -ne 0 -or $studioAPICode -ne 0 -or $goScriptCode -ne 0 -or $toolLocalCode -ne 0) { 1 } else { 0 }
    $layerResults["2"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}
# Layer 3: Mock Claude
if (3 -in $layersToRun) {
    $exitCode = Invoke-TestFile -Layer '3' -FileName 'Test-MockClaude.ps1'
    $layerResults["3"] = ($exitCode -eq 0)
    if ($exitCode -ne 0) { $overallFailed = $true }
}

# Layer 4: E2E Claude + Teams Q&A + Email Q&A + Jira Q&A
if (4 -in $layersToRun) {
    $claudeExit = Invoke-TestFile -Layer '4' -FileName 'Test-E2E-Claude.ps1'
    $teamsExit  = Invoke-TestFile -Layer '4' -FileName 'Test-E2E-Teams-QA.ps1'
    $emailExit  = Invoke-TestFile -Layer '4' -FileName 'Test-E2E-Email-QA.ps1'
    $jiraExit   = Invoke-TestFile -Layer '4' -FileName 'Test-E2E-Jira-QA.ps1'

    $layerResults["4"] = ($claudeExit -eq 0 -and $teamsExit -eq 0 -and $emailExit -eq 0 -and $jiraExit -eq 0)
    if ($claudeExit -ne 0 -or $teamsExit -ne 0 -or $emailExit -ne 0 -or $jiraExit -ne 0) { $overallFailed = $true }
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
    $files = $layerTimings[$key]
    $layerTotalMs = if ($files) { ($files | Measure-Object -Property ElapsedMs -Sum).Sum } else { 0 }
    Write-Host "  Layer $layer : $status " -NoNewline -ForegroundColor $color
    Write-Host ("({0})" -f (Format-Duration -Ms $layerTotalMs)) -ForegroundColor DarkGray
    if ($files) {
        $maxNameLen = ($files | ForEach-Object { $_.File.Length } | Measure-Object -Maximum).Maximum
        foreach ($f in ($files | Sort-Object -Property ElapsedMs -Descending)) {
            $padded = $f.File.PadRight($maxNameLen)
            Write-Host ("            {0}  {1}" -f $padded, (Format-Duration -Ms $f.ElapsedMs)) -ForegroundColor DarkGray
        }
    }
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

