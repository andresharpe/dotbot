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
Import-Module (Join-Path $ScriptDir "src" "runtime" "Modules" "DotbotCore" "DotbotCore.psm1") -Force -DisableNameChecking
$BaseDir = Get-DotbotInstallPath

# Import platform functions
$platformFunctionsPath = Join-Path $ScriptDir "src/cli/Platform-Functions.psm1"
if (Test-Path $platformFunctionsPath) {
    Import-Module $platformFunctionsPath -Force
}
$dotBotThemePath = Join-Path $ScriptDir "src/runtime/Modules/DotbotTheme/DotbotTheme.psm1"
if (Test-Path $dotBotThemePath) {
    Import-Module $dotBotThemePath -Force -DisableNameChecking
}

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-DotbotError "PowerShell 7+ is required"
    Write-DotbotWarning "Current version: $($PSVersionTable.PSVersion)"
    Write-Status "Download from: https://aka.ms/powershell"
    Write-BlankLine
    exit 1
}

# Check if we're in the dotbot repo (for global installation). Verify the
# canonical workflow exists too — a broken/partial checkout that is missing
# content/workflows/start-from-prompt/ should NOT trigger a global install.
$isInDotbotRepo = (Test-Path (Join-Path $ScriptDir "src")) -and
                  (Test-Path (Join-Path $ScriptDir "content")) -and
                  (Test-Path (Join-Path $ScriptDir "src" "cli")) -and
                  (Test-Path (Join-Path $ScriptDir "content/workflows/start-from-prompt"))

# Check if dotbot is already installed globally. Same canonical-workflow
# check on the install dir.
$isDotbotInstalled = (Test-Path $BaseDir) -and
                     (Test-Path (Join-Path $BaseDir "src")) -and
                     (Test-Path (Join-Path $BaseDir "content")) -and
                     (Test-Path (Join-Path $BaseDir "content/workflows/start-from-prompt"))

# Check if current directory has .bot (project already initialized)
$currentDir = Get-Location
$hasBotDir = Test-Path (Join-Path $currentDir ".bot")

# Determine what to do
if ($isInDotbotRepo -and -not $isDotbotInstalled) {
    # Running from dotbot repo, not yet installed globally
    Write-DotbotBanner -Title "D O T B O T   v3.5" -Subtitle "Global Installation"

    $installScript = Join-Path $ScriptDir "src/cli/install-global.ps1"
    if ($SplatArgs.Count -gt 0) {
        & $installScript @SplatArgs
    } else {
        & $installScript
    }

} elseif ($isInDotbotRepo -and $isDotbotInstalled) {
    # Running from dotbot repo but already installed - update it
    Write-BlankLine
    Write-Status "Detected: dotbot is already installed globally"
    Write-DotbotWarning "Action: Updating dotbot installation..."
    Write-BlankLine

    $installScript = Join-Path $ScriptDir "src/cli/install-global.ps1"
    if ($SplatArgs.Count -gt 0) {
        & $installScript @SplatArgs
    } else {
        & $installScript
    }

} elseif ($isDotbotInstalled -and -not $hasBotDir) {
    # dotbot is installed and we're in a project directory without .bot
    Write-BlankLine
    Write-Status "Detected: Project directory without dotbot"
    Write-DotbotWarning "Action: Initializing dotbot in current project..."
    Write-BlankLine

    # Call dotbot init
    if ($SplatArgs.Count -gt 0) {
        & dotbot init @SplatArgs
    } else {
        & dotbot init
    }

} elseif ($isDotbotInstalled -and $hasBotDir) {
    # dotbot is installed and project already has .bot
    Write-BlankLine
    Write-Status "Detected: Project already has dotbot installed"
    Write-BlankLine
    Write-DotbotCommand "dotbot status    — check installation"
    Write-DotbotCommand ".bot\go.ps1      — launch the UI"
    Write-BlankLine

} else {
    # Not in dotbot repo and dotbot not installed
    Write-DotbotBanner -Title "D O T B O T   v3.5" -Subtitle "Installation Required"
    Write-DotbotError "dotbot is not installed"
    Write-BlankLine
    Write-DotbotWarning "To install dotbot, run:"
    Write-BlankLine
    Write-DotbotCommand "git clone https://github.com/andresharpe/dotbot ~/dotbot-install"
    Write-DotbotCommand "cd ~/dotbot-install"
    Write-DotbotCommand "pwsh install.ps1"
    Write-BlankLine
}
