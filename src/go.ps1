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
Import-Module (Join-Path $PSScriptRoot "src" "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -DisableNameChecking
$global:DotbotProjectRoot = Split-Path -Parent $PSScriptRoot
$BotDir = Get-DotbotProjectBotPath
$ProjectInstallDir = Get-DotbotProjectInstallPath
$ProjectRuntimeDir = Get-DotbotProjectRuntimePath
$UIDir = Get-DotbotProjectUIPath
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
Import-Module (Join-Path $ProjectRuntimeDir "Modules" "Dotbot.Logging" "Dotbot.Logging.psm1") -Force -DisableNameChecking
Initialize-DotbotLog -LogDir $logsDir -ControlDir $controlDir -ProjectRoot (Get-DotbotProjectPath)

# Import theme module (provides Write-Status with -Type parameter)
Import-Module (Join-Path $ProjectRuntimeDir "Modules" "Dotbot.Theme" "Dotbot.Theme.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $ProjectRuntimeDir "Modules" "Dotbot.Process" "Dotbot.Process.psd1") -Force -DisableNameChecking
# Platform-Functions provides cross-platform Open-Url (xdg-open on Linux, open on macOS,
# Start-Process on Windows). Without it, the fallback Start-Process $url throws on Linux.
Import-Module (Join-Path $ProjectInstallDir "cli" "Platform-Functions.psm1") -Force -DisableNameChecking

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
                $thisProjectRoot = Get-DotbotProjectPath
                $serverInfo = $resp.Content | ConvertFrom-Json
                $serverProjectRoot = $serverInfo.project_root
                if ($serverProjectRoot -and ($serverProjectRoot -ne $thisProjectRoot)) {
                    # Different project's server on this port — start a new instance
                    Write-BotLog -Level Warn -Message "  Port $existingPort is used by a different project ($serverProjectRoot)"
                    Write-BotLog -Level Warn -Message "  Starting a new server instance..."
                } else {
                    $url = "http://localhost:$existingPort"
                    Write-Status "  Server already running on port $existingPort" -Type Success
                    Open-Url $url
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
    Write-BotLog -Level Warn -Message "Please ensure the .bot/src/ui/ directory exists and contains server.ps1"
    exit 1
}

# Start the UI server
Write-Status "  Starting UI server..." -Type Info
Write-BotLog -Level Debug -Message "   Location: $UIDir"
Write-BotLog -Level Debug -Message ""

# Build server arguments
$serverArgs = @()
if ($Port -gt 0) {
    $serverArgs += "-Port", $Port.ToString()
}

# Remove stale port file so we only read the new server's port
if (Test-Path $uiPortFile) { Remove-Item $uiPortFile -Force }

# Start the server (visible window by default; -Headless suppresses it for tests/CI)
if ($Headless) {
    $null = Start-DotbotChildProcess -File $ServerScript -FileArguments $serverArgs -WorkingDirectory (Get-DotbotProjectPath) -IsHeadless
} else {
    $null = Start-DotbotChildProcess -File $ServerScript -FileArguments $serverArgs -WorkingDirectory (Get-DotbotProjectPath)
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
    if ($Port -gt 0) {
        $resolvedPort = $Port
        Write-BotLog -Level Warn -Message "  Could not detect server port from ui-port file, falling back to requested port $resolvedPort"
    } else {
        Write-DotbotError "  Could not detect server port — the UI server did not write $uiPortFile. Check the server logs in .bot/.control/logs/."
        exit 1
    }
}

# PRD-04 User Story 8: start the per-project HTTP runtime if it isn't already
# running. The runtime is a separate process from the UI server (the UI is a
# client of the runtime per PRD-08). We launch runtime-start.ps1 as a child
# process and let it own the runtime.json lifecycle; the UI / MCP clients
# discover the URL+token via Resolve-RuntimeEndpoint.
try {
    $runtimePsd1 = Join-Path $ProjectRuntimeDir "Modules" "Dotbot.Runtime" "Dotbot.Runtime.psd1"
    if (Test-Path $runtimePsd1) {
        Import-Module $runtimePsd1 -Force -DisableNameChecking
        if (Test-RuntimeAlive -BotRoot $BotDir) {
            $existing = Read-RuntimeConnectionFile -BotRoot $BotDir
            Write-Status "  Runtime already running at $($existing.url) (PID $($existing.pid))" -Type Info
        } else {
            $runtimeStart = Join-Path $ProjectInstallDir "cli" "runtime-start.ps1"
            if (Test-Path $runtimeStart) {
                Write-Status "  Starting Dotbot runtime..." -Type Info
                $null = Start-DotbotChildProcess -File $runtimeStart -FileArguments @() -WorkingDirectory (Get-DotbotProjectPath) -IsHeadless
                # Wait briefly for the connection file to appear so callers
                # immediately downstream of `go` can discover the endpoint.
                $deadline = [DateTime]::UtcNow.AddSeconds(8)
                while ([DateTime]::UtcNow -lt $deadline) {
                    if (Test-RuntimeAlive -BotRoot $BotDir) { break }
                    Start-Sleep -Milliseconds 200
                }
                if (Test-RuntimeAlive -BotRoot $BotDir) {
                    $runtimeInfo = Read-RuntimeConnectionFile -BotRoot $BotDir
                    Write-Status "  Runtime at $($runtimeInfo.url) (PID $($runtimeInfo.pid))" -Type Success
                } else {
                    Write-BotLog -Level Warn -Message "Runtime did not come up within 8s — check 'dotbot runtime-status'."
                }
            } else {
                Write-BotLog -Level Warn -Message "runtime-start.ps1 not found at $runtimeStart — skipping runtime launch."
            }
        }
    } else {
        Write-BotLog -Level Debug -Message "Dotbot.Runtime module not present — skipping runtime launch (older install?)"
    }
} catch {
    Write-BotLog -Level Warn -Message "Could not start the Dotbot runtime" -Exception $_
}

$url = "http://localhost:$resolvedPort"
Open-Url $url

Write-Status "  Browser opened at $url" -Type Success
Write-BotLog -Level Debug -Message "   Server is running in a separate window (port $resolvedPort)."
Write-BotLog -Level Debug -Message ""
