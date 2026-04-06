#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Launch the dotbot studio.

.DESCRIPTION
    Starts the studio server (or attaches to an already-running
    instance) and opens the browser. In dev mode (-Dev) it starts both the
    Vite dev server and the API backend via concurrently.

.PARAMETER Port
    Base port for the API server (default 9001). The Vite dev server always
    uses 5173 in dev mode.

.PARAMETER Dev
    Run in development mode with hot-reload (Vite + API concurrently).

.EXAMPLE
    pwsh go.ps1            # production / preview mode
    pwsh go.ps1 -Dev       # development mode with hot-reload
    pwsh go.ps1 -Port 9100 # custom API port
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 65535)]
    [int]$Port = 9001,

    [switch]$Dev
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# ---------------------------------------------------------------------------
# Check for an already-running instance
# ---------------------------------------------------------------------------
$portFile = Join-Path $HOME 'dotbot' '.studio-port'
if (Test-Path $portFile) {
    try {
        $info = Get-Content $portFile -Raw | ConvertFrom-Json
        $existingPort = $info.port
        $existingPid = $info.pid
        if ($existingPort -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
            $url = "http://localhost:$existingPort"
            Write-Host ""
            Write-Host "  dotbot studio already running on port $existingPort" -ForegroundColor Green
            Start-Process $url
            Write-Host "  Browser opened at $url" -ForegroundColor Green
            Write-Host ""
            exit 0
        }
    } catch {
        # Stale port file — continue with fresh start
    }
}

# ---------------------------------------------------------------------------
# Ensure dependencies are installed
# ---------------------------------------------------------------------------
$nodeModules = Join-Path $scriptDir 'node_modules'
if (-not (Test-Path $nodeModules)) {
    Write-Host ""
    Write-Host "  Installing dependencies..." -ForegroundColor Yellow
    Push-Location $scriptDir
    try {
        npm install
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  npm install failed." -ForegroundColor Red
            exit 1
        }
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Dev mode — run Vite + API concurrently in this terminal
# ---------------------------------------------------------------------------
if ($Dev) {
    Write-Host ""
    Write-Host "  Starting dotbot studio (dev mode)..." -ForegroundColor Cyan
    Write-Host "  Vite:  http://localhost:5173" -ForegroundColor Green
    Write-Host "  API:   http://localhost:$Port" -ForegroundColor Green
    Write-Host "  Press Ctrl+C to stop." -ForegroundColor Yellow
    Write-Host ""

    # Brief delay then open browser
    Start-Job -ScriptBlock {
        Start-Sleep -Seconds 4
        Start-Process "http://localhost:5173"
    } | Out-Null

    Push-Location $scriptDir
    try {
        npm run dev
    } finally {
        Pop-Location
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Production mode — build if needed, then start server
# ---------------------------------------------------------------------------
$staticDir = Join-Path $scriptDir 'static'
$indexFile = Join-Path $staticDir 'index.html'
if (-not (Test-Path $indexFile)) {
    Write-Host ""
    Write-Host "  Building studio client..." -ForegroundColor Yellow
    Push-Location $scriptDir
    try {
        npm run build
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Build failed." -ForegroundColor Red
            exit 1
        }
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "  Starting dotbot studio..." -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

$serverScript = Join-Path $scriptDir 'server.ps1'
& pwsh -NoProfile -File $serverScript -Port $Port
