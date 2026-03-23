#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot Smart Installation Script
    Automatically detects context and runs the appropriate installation

.DESCRIPTION
    - From repo root: Installs dotbot globally
    - From project directory (with dotbot installed): Initializes .bot in project

.EXAMPLE
    ./install.ps1
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RawArguments
)

Set-StrictMode -Version 3.0

# Convert CLI args to a hashtable for proper named-parameter splatting.
# Array splatting only does positional binding; hashtable splatting is
# required for named parameters like -Workflow / -Stack.
$SplatArgs = @{}
if ($RawArguments) {
    $i = 0
    while ($i -lt $RawArguments.Count) {
        $token = $RawArguments[$i]
        if ($token -match '^--?(.+)$') {
            $name = $Matches[1]
            if (($i + 1) -lt $RawArguments.Count -and $RawArguments[$i + 1] -notmatch '^--?') {
                $SplatArgs[$name] = $RawArguments[$i + 1]
                $i += 2
            } else {
                $SplatArgs[$name] = $true
                $i++
            }
        } else {
            $i++
        }
    }
}

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$BaseDir = Join-Path $HOME "dotbot"

# Import platform functions
$platformFunctionsPath = Join-Path $ScriptDir "scripts\Platform-Functions.psm1"
if (Test-Path $platformFunctionsPath) {
    Import-Module $platformFunctionsPath -Force
}

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ""
    Write-Host "  ✗ PowerShell 7+ is required" -ForegroundColor Red
    Write-Host "    Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "    Download from: https://aka.ms/powershell" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

# Check if we're in the dotbot repo (for global installation)
$isInDotbotRepo = (Test-Path (Join-Path $ScriptDir "workflows\default")) -and 
                  (Test-Path (Join-Path $ScriptDir "scripts"))

# Check if dotbot is already installed globally
$isDotbotInstalled = (Test-Path $BaseDir) -and 
                     (Test-Path (Join-Path $BaseDir "workflows\default"))

# Check if current directory has .bot (project already initialized)
$currentDir = Get-Location
$hasBotDir = Test-Path (Join-Path $currentDir ".bot")

# Determine what to do
if ($isInDotbotRepo -and -not $isDotbotInstalled) {
    # Running from dotbot repo, not yet installed globally
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v3.5" -ForegroundColor Blue
    Write-Host "    Global Installation" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    $installScript = Join-Path $ScriptDir "scripts\install-global.ps1"
    if ($SplatArgs.Count -gt 0) {
        & $installScript @SplatArgs
    } else {
        & $installScript
    }
    
} elseif ($isInDotbotRepo -and $isDotbotInstalled) {
    # Running from dotbot repo but already installed - update it
    Write-Host ""
    Write-Host "  Detected: dotbot is already installed globally" -ForegroundColor Cyan
    Write-Host "  Action: Updating dotbot installation..." -ForegroundColor Yellow
    Write-Host ""
    
    $installScript = Join-Path $ScriptDir "scripts\install-global.ps1"
    if ($SplatArgs.Count -gt 0) {
        & $installScript @SplatArgs
    } else {
        & $installScript
    }
    
} elseif ($isDotbotInstalled -and -not $hasBotDir) {
    # dotbot is installed and we're in a project directory without .bot
    Write-Host ""
    Write-Host "  Detected: Project directory without dotbot" -ForegroundColor Cyan
    Write-Host "  Action: Initializing dotbot in current project..." -ForegroundColor Yellow
    Write-Host ""
    
    # Call dotbot init
    if ($SplatArgs.Count -gt 0) {
        & dotbot init @SplatArgs
    } else {
        & dotbot init
    }
    
} elseif ($isDotbotInstalled -and $hasBotDir) {
    # dotbot is installed and project already has .bot
    Write-Host ""
    Write-Host "  Detected: Project already has dotbot installed" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Use 'dotbot status' to check installation" -ForegroundColor Yellow
    Write-Host "  Use '.bot\go.ps1' to launch the UI" -ForegroundColor Yellow
    Write-Host ""
    
} else {
    # Not in dotbot repo and dotbot not installed
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v3.5" -ForegroundColor Blue
    Write-Host "    Installation Required" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ✗ dotbot is not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "  To install dotbot, run:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    git clone https://github.com/andresharpe/dotbot ~/dotbot-install" -ForegroundColor White
    Write-Host "    cd ~/dotbot-install" -ForegroundColor White
    Write-Host "    pwsh install.ps1" -ForegroundColor White
    Write-Host ""
}
