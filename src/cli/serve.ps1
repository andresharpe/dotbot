#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot serve — bring up the per-project HTTP runtime in the foreground.

.DESCRIPTION
    Serves the per-project HTTP runtime in the foreground in the current
    shell. Use it for:
      - Diagnostics: start the runtime by itself, no UI server.
      - Tests: a non-interactive shell that just wants the HTTP surface.
      - Background mode: a wrapper can launch this script in the background
        and trust the connection file to communicate the URL.
      - Fleet mode: pass --mothership <dashboard-url> so this runtime registers
        with a mothership dashboard on startup.

    The runtime runs until Ctrl+C is pressed or the process is killed; on
    exit it removes .bot/.control/runtime.json so the next start gets a
    fresh token.
#>

[CmdletBinding()]
param(
    [string]$Mothership,

    [Alias('mothership-key')]
    [string]$MothershipApiKey
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Import-Module (Join-Path $PSScriptRoot 'Platform-Functions.psm1') -Force

function Find-BotRoot {
    $cur = (Get-Location).Path
    while ($cur) {
        $candidate = Join-Path $cur '.bot'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        if (Test-Path -LiteralPath (Join-Path $cur '.git')) { return $null }
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

if ($Mothership) {
    $env:DOTBOT_MOTHERSHIP_URL = $Mothership
}
if ($MothershipApiKey) {
    $env:DOTBOT_MOTHERSHIP_API_KEY = $MothershipApiKey
}

$start = Start-DotbotRuntime -BotRoot $botRoot
if ($start.attached) {
    Write-Success ("Runtime is already running at {0} (PID {1})." -f $start.url, $start.pid)
    Write-DotbotCommand "Use 'dotbot runtime-status' to inspect it."
    exit 0
}

Write-BlankLine
Write-DotbotSection "DOTBOT RUNTIME"
Write-DotbotLabel "URL:"        $start.url        -ValueType Success
Write-DotbotLabel "PID:"        ([string]$start.pid)
Write-DotbotLabel "Started:"    $start.started_at
Write-DotbotLabel "Conn file:"  (Get-RuntimeConnectionFilePath -BotRoot $botRoot)
Write-BlankLine
Write-DotbotCommand "Press Ctrl+C to stop."
Write-BlankLine

# Ensure cleanup on Ctrl+C / process exit. The PowerShell event handler is
# best-effort — .NET ProcessExit covers normal shutdown paths.
$cleanupRan = $false
$cleanup = {
    if ($script:cleanupRan) { return }
    $script:cleanupRan = $true
    try { Stop-DotbotRuntime -BotRoot $botRoot -Listener $start.listener -ControlPlaneRegistration $start.control_plane -ErrorAction SilentlyContinue } catch { $null = $_ }
}
try {
    [Console]::CancelKeyPress.Add({ param($s, $e) $e.Cancel = $true; & $cleanup })
} catch { $null = $_ }
[System.AppDomain]::CurrentDomain.add_ProcessExit({ & $cleanup })

try {
    while ($start.listener.IsListening) { Start-Sleep -Milliseconds 250 }
} finally {
    & $cleanup
}
