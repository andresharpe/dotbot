#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests for #367: activity-log hygiene.
.DESCRIPTION
    Covers three of the four sub-bugs in #367:
      1. ClaudeCLI.psm1's compaction catch-all no longer fires for
         unrecognised system events with no message.
      3. launch-process.ps1 resets DOTBOT_CORRELATION_ID at startup so
         child processes do not inherit the parent's value via env vars.
      4. UI server (core/ui/server.ps1) seeds DOTBOT_CORRELATION_ID at
         startup so events such as the Aether-conduit-discovered log
         carry a correlation_id.

    Sub-bug 2 (sub-agent task_started/task_progress/task_notification
    pair semantics) is intentionally not addressed by this PR — the
    upstream Claude Code intent could not be confirmed, and the issue
    body authorises shipping 1, 3, 4 only in that case.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host "  Activity-Log Hygiene Tests" -ForegroundColor Blue
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ─── Sub-bug 1: compaction catch-all is gated on an explicit signal ──────────

$claudeCliPath = Join-Path $repoRoot "core/runtime/ClaudeCLI/ClaudeCLI.psm1"
Assert-PathExists -Name "ClaudeCLI.psm1 exists" -Path $claudeCliPath
$claudeCliSource = Get-Content $claudeCliPath -Raw

Assert-True -Name "Compaction emission is gated on `$isCompact" `
    -Condition ($claudeCliSource -match '\$isCompact\s*=') `
    -Message "Expected ClaudeCLI.psm1 to compute an isCompact gate before emitting the 'compact' activity event"

Assert-True -Name "Compact gate references compact_boundary subtype" `
    -Condition ($claudeCliSource -match "compact_boundary") `
    -Message "Expected the compact gate to recognise 'compact_boundary' as an explicit subtype"

Assert-True -Name "Compact gate short-circuits when not compact" `
    -Condition ($claudeCliSource -match 'if\s*\(-not\s*\$isCompact\)\s*\{\s*return\s*\}') `
    -Message "Expected `if (-not `$isCompact) { return }` after the gate"

# ─── Sub-bug 3: launch-process.ps1 resets DOTBOT_CORRELATION_ID early ────────

$launchProcessPath = Join-Path $repoRoot "core/runtime/launch-process.ps1"
Assert-PathExists -Name "launch-process.ps1 exists" -Path $launchProcessPath
$launchProcessSource = Get-Content $launchProcessPath -Raw

Assert-True -Name "launch-process.ps1 sets DOTBOT_CORRELATION_ID unconditionally" `
    -Condition ($launchProcessSource -match '\$env:DOTBOT_CORRELATION_ID\s*=\s*"corr-') `
    -Message "Expected an unconditional reset of DOTBOT_CORRELATION_ID in launch-process.ps1"

Assert-True -Name "launch-process.ps1 reset is not gated by a `if (-not env:DOTBOT_CORRELATION_ID)` check" `
    -Condition (-not ($launchProcessSource -match 'if\s*\(\s*-not\s*\$env:DOTBOT_CORRELATION_ID\s*\)')) `
    -Message "Expected the inherited-value guard to be gone (the bug was that inheriting leaked correlation_ids across processes)"

$launchProcessLines = $launchProcessSource -split "`r?`n"
$resetLine = $null
for ($i = 0; $i -lt $launchProcessLines.Count; $i++) {
    if ($launchProcessLines[$i] -match '^\s*\$env:DOTBOT_CORRELATION_ID\s*=\s*"corr-') {
        $resetLine = $i + 1
        break
    }
}
Assert-True -Name "DOTBOT_CORRELATION_ID reset happens early (before line 100)" `
    -Condition ($resetLine -ne $null -and $resetLine -lt 100) `
    -Message "Expected reset to happen before any Write-BotLog calls; found at line $resetLine"

# ─── Sub-bug 4: UI server seeds DOTBOT_CORRELATION_ID at startup ─────────────

$serverPath = Join-Path $repoRoot "core/ui/server.ps1"
Assert-PathExists -Name "server.ps1 exists" -Path $serverPath
$serverSource = Get-Content $serverPath -Raw

Assert-True -Name "server.ps1 seeds DOTBOT_CORRELATION_ID with a corr-ui- prefix" `
    -Condition ($serverSource -match '\$env:DOTBOT_CORRELATION_ID\s*=\s*"corr-ui-') `
    -Message "Expected server.ps1 to seed a corr-ui-* value at startup so Aether and other handler-emitted events carry a correlation_id"

Assert-True -Name "server.ps1 reset is unconditional (no `if (-not env:DOTBOT_CORRELATION_ID)` gate)" `
    -Condition (-not ($serverSource -match 'if\s*\(\s*-not\s*\$env:DOTBOT_CORRELATION_ID\s*\)\s*\{[^}]*"corr-ui-')) `
    -Message "Expected the seed to be unconditional; gating on the inherited value would let the parent's correlation_id leak through"

$allPassed = Write-TestSummary -LayerName "Activity-Log Hygiene Tests"

if (-not $allPassed) {
    exit 1
}
