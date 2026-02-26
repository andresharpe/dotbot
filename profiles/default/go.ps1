#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Launch the .bot UI server and open the browser.

.DESCRIPTION
    This script starts the web-based task management UI and automatically opens
    it in your default browser. The UI server runs in the background.

.NOTES
    Press Ctrl+C to stop the server when done.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Test-PortAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $tcpListener = $null
    try {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $tcpListener.Start()
    } catch {
        return $false
    } finally {
        if ($null -ne $tcpListener) {
            try { $tcpListener.Stop() } catch { }
        }
    }

    # The UI server uses HttpListener. Validate the HTTP prefix too, otherwise
    # TcpListener-only probing can miss an existing localhost HTTP registration.
    $httpListener = [System.Net.HttpListener]::new()
    try {
        $httpListener.Prefixes.Add("http://localhost:$Port/")
        $httpListener.Start()
        return $true
    } catch {
        return $false
    } finally {
        try {
            if ($httpListener.IsListening) {
                $httpListener.Stop()
            }
        } catch { }
        try { $httpListener.Close() } catch { }
    }
}

function Get-NextAvailablePort {
    param(
        [int]$StartPort = 8686,
        [int]$MaxPort = 65535
    )

    for ($port = $StartPort; $port -le $MaxPort; $port++) {
        if (Test-PortAvailable -Port $port) {
            return $port
        }
    }

    return $null
}

# Get directories
$BotDir = $PSScriptRoot
$UIDir = Join-Path $BotDir "systems\ui"
$ServerScript = Join-Path $UIDir "server.ps1"

# Log startup to unified diagnostic log
$controlDir = Join-Path $BotDir ".control"
if (-not (Test-Path $controlDir)) { New-Item -Path $controlDir -ItemType Directory -Force | Out-Null }
$diagLog = Join-Path $controlDir "diag.log"
"$(Get-Date -Format o) [STARTUP] go.ps1 launched. BotDir=$BotDir" | Add-Content -Path $diagLog

Write-Host "  Starting .bot UI..." -ForegroundColor Cyan
Write-Host ""

# Check if server script exists
if (-not (Test-Path $ServerScript)) {
    Write-Host "  Error: UI server script not found at:" -ForegroundColor Red
    Write-Host "   $ServerScript" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please ensure the .bot/systems/ui/ directory exists and contains server.ps1" -ForegroundColor Yellow
    exit 1
}

# Import platform functions
$DotbotBase = Join-Path $HOME "dotbot"
$PlatformModule = Join-Path $DotbotBase "scripts\Platform-Functions.psm1"
if (Test-Path $PlatformModule) {
    Import-Module $PlatformModule -Force
}

# Start the UI server
Write-Host "  Starting UI server..." -ForegroundColor Yellow
Write-Host "   Location: $UIDir" -ForegroundColor DarkGray
Write-Host ""

$selectedPort = Get-NextAvailablePort
if ($null -eq $selectedPort) {
    Write-Host "  Error: No available TCP port found from 8686 to 65535." -ForegroundColor Red
    exit 1
}

$uiUrl = "http://localhost:$selectedPort"
"$(Get-Date -Format o) [STARTUP] go.ps1 selected UI URL: $uiUrl" | Add-Content -Path $diagLog

# Start the server in a new PowerShell window
Start-Process pwsh -ArgumentList "-File", "`"$ServerScript`"", "-Port", "$selectedPort"

# Open browser after a short delay
Start-Sleep -Seconds 2
if (Get-Command Open-Url -ErrorAction SilentlyContinue) {
    Open-Url $uiUrl
} else {
    Start-Process $uiUrl
}

Write-Host "  Browser opened at $uiUrl" -ForegroundColor Green
Write-Host "   Server is running in a separate window." -ForegroundColor DarkGray
Write-Host ""
