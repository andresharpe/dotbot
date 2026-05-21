#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot runtime-status — show PID, URL, and active runs of the per-project HTTP runtime.

.DESCRIPTION
    Verifies the runtime described by .bot/.control/runtime.json is alive
    (Test-RuntimeAlive), then queries its HTTP surface for the list of
    active workflow runs.

    Output uses the standard CLI theme helpers from Platform-Functions.psm1
    (CLAUDE.md output-hygiene rule).

    Exit codes:
      0  runtime alive and reachable
      1  runtime not running (no runtime.json, or stale PID)
      2  runtime PID alive but HTTP endpoint unreachable
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Import-Module (Join-Path $PSScriptRoot 'Platform-Functions.psm1') -Force

function Find-BotRoot {
    $cur = (Get-Location).Path
    while ($cur) {
        $candidate = Join-Path $cur '.bot'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}

$botRoot = Find-BotRoot
if (-not $botRoot) {
    Write-DotbotError "Could not find a .bot/ directory in this or any parent path."
    Write-DotbotCommand "Run 'dotbot init' first."
    exit 1
}

# Locate the installed runtime module — the per-project .bot/ has src/runtime/Modules/
$runtimePsd1 = Join-Path $botRoot (Join-Path 'src' (Join-Path 'runtime' (Join-Path 'Modules' (Join-Path 'Dotbot.Runtime' 'Dotbot.Runtime.psd1'))))
if (-not (Test-Path -LiteralPath $runtimePsd1)) {
    # Dev fallback: walk up to find the repo root.
    $repoCandidate = $botRoot
    while ($repoCandidate) {
        $alt = Join-Path $repoCandidate (Join-Path 'src' (Join-Path 'runtime' (Join-Path 'Modules' (Join-Path 'Dotbot.Runtime' 'Dotbot.Runtime.psd1'))))
        if (Test-Path -LiteralPath $alt) { $runtimePsd1 = $alt; break }
        $up = Split-Path $repoCandidate -Parent
        if (-not $up -or $up -eq $repoCandidate) { $runtimePsd1 = $null; break }
        $repoCandidate = $up
    }
}
if (-not $runtimePsd1) {
    Write-DotbotError "Dotbot.Runtime module not found. Reinstall with 'pwsh install.ps1' from the dotbot repo."
    exit 1
}

Import-Module $runtimePsd1 -DisableNameChecking -Force

Write-DotbotSection "RUNTIME"

$connPath = Get-RuntimeConnectionFilePath -BotRoot $botRoot
if (-not (Test-Path -LiteralPath $connPath)) {
    Write-DotbotLabel "Status:" "✗ Not running" -ValueType Error
    Write-DotbotLabel "Reason:" "no .bot/.control/runtime.json"
    Write-BlankLine
    Write-DotbotWarning "Start the runtime with 'dotbot go' (or 'dotbot runtime-start')."
    exit 1
}

$conn  = Read-RuntimeConnectionFile -BotRoot $botRoot
$alive = Test-RuntimeAlive -BotRoot $botRoot

$statusText = if ($alive) { "✓ Alive" } else { "✗ Stale (PID gone)" }
$statusType = if ($alive) { "Success" } else { "Error" }
Write-DotbotLabel "Status:"     $statusText             -ValueType $statusType
Write-DotbotLabel "PID:"        ([string]$conn.pid)
Write-DotbotLabel "URL:"        ([string]$conn.url)
Write-DotbotLabel "Started at:" ([string]$conn.started_at)
Write-DotbotLabel "Conn file:"  $connPath
Write-BlankLine

if (-not $alive) {
    Write-DotbotWarning "The PID recorded in runtime.json is no longer running."
    Write-DotbotWarning "The next 'dotbot go' will rewrite runtime.json with a fresh token."
    exit 1
}

# Query active runs via the HTTP surface.
Write-DotbotSection "ACTIVE RUNS"
try {
    $resp = Invoke-RuntimeRequest -BotRoot $botRoot -Method GET -Path '/workflows/runs'
} catch {
    Write-DotbotLabel "Status:" "✗ Unreachable" -ValueType Error
    Write-DotbotLabel "Reason:" $_.Exception.Message
    exit 2
}
if ($resp.status_code -ne 200) {
    Write-DotbotLabel "Status:" ("✗ HTTP {0}" -f $resp.status_code) -ValueType Error
    exit 2
}
$runs = @()
foreach ($r in @($resp.body.runs)) {
    $status = if ($r.status -and $r.status.status) { [string]$r.status.status } else { '?' }
    if ($status -eq 'running') { $runs += $r }
}
if ($runs.Count -eq 0) {
    Write-DotbotLabel "Total:" "0 active"
    Write-BlankLine
    exit 0
}
foreach ($r in $runs) {
    $name = if ($r.run -and $r.run.workflow_name) { [string]$r.run.workflow_name } else { '<unknown>' }
    $id   = if ($r.run -and $r.run.run_id)        { [string]$r.run.run_id }        else { '<unknown>' }
    $iso  = if ($r.run -and $null -ne $r.run.isolated) { [bool]$r.run.isolated } else { $false }
    $isoTxt = if ($iso) { 'isolated' } else { 'non-isolated' }
    Write-DotbotLabel ("• " + $id) ("{0}  ({1})" -f $name, $isoTxt)
}
Write-BlankLine
exit 0
