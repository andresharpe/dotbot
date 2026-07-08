#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Aether client-side event-bus wiring (PRD-031 AC#8 / AC#9).
.DESCRIPTION
    Source-level assertions that the browser Aether module drives its
    lights/oscilloscope from task.* / workflow.* events on the activity tail,
    with the old /api/state diffing removed — and that the activity tail poll
    itself is untouched.

    The frontend has no JS unit harness in this suite, so these are static
    source checks (same approach as the other UI/source assertions).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Aether event-bus wiring" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$aetherPath  = Join-Path $repoRoot 'src/ui/static/modules/aether.js'
$pollingPath = Join-Path $repoRoot 'src/ui/static/modules/polling.js'
Assert-PathExists -Name "aether.js exists"  -Path $aetherPath
Assert-PathExists -Name "polling.js exists" -Path $pollingPath

$aether  = Get-Content -LiteralPath $aetherPath  -Raw
$polling = Get-Content -LiteralPath $pollingPath -Raw

# ── AC#8: /api/state diffing removed ──
Assert-True -Name "aether.js no longer defines processState (diffing removed)" `
    -Condition (-not ($aether -match 'function\s+processState'))
Assert-True -Name "aether.js no longer references processState at all" `
    -Condition (-not ($aether -match 'processState'))
Assert-True -Name "polling.js no longer calls Aether.processState" `
    -Condition (-not ($polling -match 'Aether\.processState'))

# ── AC#8: Aether drives from task.* / workflow.* events ──
Assert-True -Name "aether.js handles task.status_changed"     -Condition ($aether -match 'task\.status_changed')
Assert-True -Name "aether.js handles workflow.run_completed"  -Condition ($aether -match 'workflow\.run_completed')
Assert-True -Name "aether.js handles workflow.run_failed"     -Condition ($aether -match 'workflow\.run_failed')
Assert-True -Name "aether.js reacts to the 'in-progress' task transition" -Condition ($aether -match "in-progress")

# ── AC#9: the activity-tail poll is still wired (oscilloscope/tail untouched) ──
Assert-True -Name "aether.js still exports processActivity"     -Condition ($aether -match '(?m)^\s*processActivity,')
Assert-True -Name "polling.js still feeds Aether.processActivity from the tail" -Condition ($polling -match 'Aether\.processActivity')
Assert-True -Name "polling.js still polls /api/activity/tail"   -Condition ($polling -match '/api/activity/tail')

$allPassed = Write-TestSummary -LayerName "Layer 1: Aether event-bus wiring"

if (-not $allPassed) {
    exit 1
}
