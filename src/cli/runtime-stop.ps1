#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot runtime stop — stop the per-project HTTP runtime and clear its connection file.

.DESCRIPTION
    A runtime auto-started for a detached run outlives the command that started
    it and has no console to close, so Stop-Process against the PID recorded in
    .bot/.control/runtime.json is the only way to stop it. Stop-DotbotRuntime
    cannot do this: it needs the in-process HttpListener handle.

    "Nothing to stop" is success, matching tasks-stop.ps1.

    Exit codes:
      0  runtime stopped, or no runtime was running
      1  no .bot/ directory, module missing, or the process refused to stop
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

$conn = Read-RuntimeConnectionFile -BotRoot $botRoot
if (-not $conn -or -not $conn.pid) {
    Write-DotbotLabel "Status:" "Not running" -ValueType Info
    Write-BlankLine
    Write-DotbotCommand "Nothing to stop — no .bot/.control/runtime.json."
    exit 0
}

$runtimePid = $conn.pid
$proc = Get-Process -Id $runtimePid -ErrorAction SilentlyContinue

if (-not ($proc -and $proc.ProcessName -match 'pwsh|powershell')) {
    Remove-RuntimeConnectionFile -BotRoot $botRoot
    Write-DotbotLabel "Status:" "Not running" -ValueType Info
    Write-BlankLine
    Write-DotbotCommand "Cleared a stale connection file for PID $runtimePid."
    exit 0
}

Stop-Process -Id $runtimePid -Force
Remove-RuntimeConnectionFile -BotRoot $botRoot

Write-DotbotLabel "Status:" "Stopped" -ValueType Success
Write-DotbotLabel "PID:" ([string]$runtimePid)
Write-DotbotLabel "URL:" ([string]$conn.url)
Write-BlankLine
Write-Success "Runtime stopped and connection file removed."
exit 0
