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

$runtimePsd1 = Join-Path $PSScriptRoot '../runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1'
if (-not (Test-Path -LiteralPath $runtimePsd1)) {
    Write-DotbotError "Dotbot.Runtime module not found at $runtimePsd1. Set `$env:DOTBOT_HOME to a dotbot checkout with src/runtime/Modules/Dotbot.Runtime/."
    exit 1
}

Import-Module $runtimePsd1 -DisableNameChecking -Force

Write-DotbotSection "RUNTIME"

$connPath = Get-RuntimeConnectionFilePath -BotRoot $botRoot
if (-not (Test-Path -LiteralPath $connPath)) {
    Write-DotbotLabel "Status:" "✗ Not running" -ValueType Error
    Write-DotbotLabel "Reason:" "no .bot/.control/runtime.json"
    Write-BlankLine
    Write-DotbotWarning "Start the runtime with 'dotbot serve'."
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
    Write-DotbotWarning "The next 'dotbot serve' will rewrite runtime.json with a fresh token."
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
    Write-DotbotLabel ("• " + $id) $name
}
Write-BlankLine
exit 0
