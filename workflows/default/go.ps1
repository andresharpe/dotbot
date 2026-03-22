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
param(
    [Parameter(Mandatory = $false)]
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"

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

# Check if a server is already running for this project
$uiPortFile = Join-Path $controlDir "ui-port"
if (Test-Path $uiPortFile) {
    $existingPort = (Get-Content $uiPortFile -Raw).Trim()
    if ($existingPort -match '^\d+$') {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$existingPort/api/info" -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                # Verify the server belongs to THIS project, not a different one
                $thisProjectRoot = (Resolve-Path (Join-Path $BotDir "..")).Path
                $serverInfo = $resp.Content | ConvertFrom-Json
                $serverProjectRoot = $serverInfo.project_root
                if ($serverProjectRoot -and ($serverProjectRoot -ne $thisProjectRoot)) {
                    # Different project's server on this port — start a new instance
                    Write-Host "  Port $existingPort is used by a different project ($serverProjectRoot)" -ForegroundColor Yellow
                    Write-Host "  Starting a new server instance..." -ForegroundColor Yellow
                } else {
                    $url = "http://localhost:$existingPort"
                    Write-Host "  Server already running on port $existingPort" -ForegroundColor Green
                    if (Get-Command Open-Url -ErrorAction SilentlyContinue) {
                        Open-Url $url
                    } else {
                        Start-Process $url
                    }
                    Write-Host "  Browser opened at $url" -ForegroundColor Green
                    Write-Host ""
                    exit 0
                }
            }
        } catch {
            # Server not responding — stale port file, continue with fresh start
        }
    }
}

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

# Build server arguments
$serverArgs = @("-File", "`"$ServerScript`"")
if ($Port -gt 0) {
    $serverArgs += "-Port", $Port.ToString()
}

# Remove stale port file so we only read the new server's port
if (Test-Path $uiPortFile) { Remove-Item $uiPortFile -Force }

# Start the server in a new PowerShell window
Start-Process pwsh -ArgumentList $serverArgs

# Wait for the server to write its selected port
$resolvedPort = 0
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path $uiPortFile) {
        $raw = (Get-Content $uiPortFile -Raw).Trim()
        if ($raw -match '^\d+$') {
            $resolvedPort = [int]$raw
            break
        }
    }
}

if ($resolvedPort -eq 0) {
    $resolvedPort = if ($Port -gt 0) { $Port } else { 8686 }
    Write-Host "  Could not detect server port, assuming $resolvedPort" -ForegroundColor Yellow
}

$url = "http://localhost:$resolvedPort"
if (Get-Command Open-Url -ErrorAction SilentlyContinue) {
    Open-Url $url
} else {
    Start-Process $url
}

Write-Host "  Browser opened at $url" -ForegroundColor Green
Write-Host "   Server is running in a separate window (port $resolvedPort)." -ForegroundColor DarkGray
Write-Host ""
