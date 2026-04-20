#!/usr/bin/env pwsh
# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
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
    [int]$Port = 0,

    [Parameter(Mandatory = $false)]
    [switch]$Headless
)

$ErrorActionPreference = "Stop"

# Get directories
$BotDir = $PSScriptRoot
$UIDir = Join-Path $BotDir "systems\ui"
$ServerScript = Join-Path $UIDir "server.ps1"

# Migrate legacy folder names if needed (defaults→settings, prompts→recipes, adrs→decisions)
$oldDefaults = Join-Path $BotDir "defaults"
$newSettings = Join-Path $BotDir "settings"
if ((Test-Path $oldDefaults) -and -not (Test-Path $newSettings)) { Rename-Item $oldDefaults $newSettings }
$oldInner = Join-Path $BotDir "prompts\workflows"
if (Test-Path $oldInner) { Rename-Item $oldInner (Join-Path $BotDir "prompts\_prompts_tmp") }
$oldPrompts = Join-Path $BotDir "prompts"
$newRecipes = Join-Path $BotDir "recipes"
if ((Test-Path $oldPrompts) -and -not (Test-Path $newRecipes)) {
    Rename-Item $oldPrompts $newRecipes
    $tmp = Join-Path $newRecipes "_prompts_tmp"
    if (Test-Path $tmp) { Rename-Item $tmp (Join-Path $newRecipes "prompts") }
}
$oldAdrs = Join-Path $BotDir "workspace\adrs"
$newDec = Join-Path $BotDir "workspace\decisions"
if ((Test-Path $oldAdrs) -and -not (Test-Path $newDec)) { Rename-Item $oldAdrs $newDec }

# Initialize structured logging
$controlDir = Join-Path $BotDir ".control"
if (-not (Test-Path $controlDir)) { New-Item -Path $controlDir -ItemType Directory -Force | Out-Null }
$logsDir = Join-Path $controlDir "logs"
if (-not (Test-Path $logsDir)) { New-Item -Path $logsDir -ItemType Directory -Force | Out-Null }
Import-Module "$PSScriptRoot\systems\runtime\modules\DotBotLog.psm1" -Force -DisableNameChecking
Initialize-DotBotLog -LogDir $logsDir -ControlDir $controlDir -ProjectRoot (Split-Path $BotDir -Parent)

# Import theme module (provides Write-Status with -Type parameter)
Import-Module "$PSScriptRoot\systems\runtime\modules\DotBotTheme.psm1" -Force -DisableNameChecking

Write-BotLog -Level Info -Message "go.ps1 launched. BotDir=$BotDir"

Write-Status "  Starting .bot UI..." -Type Info
Write-BotLog -Level Debug -Message ""

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
                    Write-BotLog -Level Warn -Message "  Port $existingPort is used by a different project ($serverProjectRoot)"
                    Write-BotLog -Level Warn -Message "  Starting a new server instance..."
                } else {
                    $url = "http://localhost:$existingPort"
                    Write-Status "  Server already running on port $existingPort" -Type Success
                    if (Get-Command Open-Url -ErrorAction SilentlyContinue) {
                        Open-Url $url
                    } else {
                        Start-Process $url
                    }
                    Write-Status "  Browser opened at $url" -Type Success
                    Write-BotLog -Level Debug -Message ""
                    exit 0
                }
            }
        } catch {
            Write-BotLog -Level Debug -Message "Server not responding on stale port — continuing with fresh start" -Exception $_
        }
    }
}

# Check if server script exists
if (-not (Test-Path $ServerScript)) {
    Write-BotLog -Level Error -Message "  Error: UI server script not found at:"
    Write-BotLog -Level Error -Message "   $ServerScript"
    Write-BotLog -Level Debug -Message ""
    Write-BotLog -Level Warn -Message "Please ensure the .bot/systems/ui/ directory exists and contains server.ps1"
    exit 1
}

# Start the UI server
Write-Status "  Starting UI server..." -Type Info
Write-BotLog -Level Debug -Message "   Location: $UIDir"
Write-BotLog -Level Debug -Message ""

# Build server arguments
$serverArgs = @("-File", "`"$ServerScript`"")
if ($Port -gt 0) {
    $serverArgs += "-Port", $Port.ToString()
}

# Remove stale port file so we only read the new server's port
if (Test-Path $uiPortFile) { Remove-Item $uiPortFile -Force }

# Start the server (visible window by default; -Headless suppresses it for tests/CI)
if ($Headless) {
    Start-Process pwsh -ArgumentList $serverArgs -NoNewWindow
} else {
    Start-Process pwsh -ArgumentList $serverArgs
}

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
    Write-BotLog -Level Warn -Message "  Could not detect server port, assuming $resolvedPort"
}

$url = "http://localhost:$resolvedPort"
if (Get-Command Open-Url -ErrorAction SilentlyContinue) {
    Open-Url $url
} else {
    Start-Process $url
}

Write-Status "  Browser opened at $url" -Type Success
Write-BotLog -Level Debug -Message "   Server is running in a separate window (port $resolvedPort)."
Write-BotLog -Level Debug -Message ""
