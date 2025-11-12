# =============================================================================
# dotbot Smart Initialization Script
# Automatically detects context and runs the appropriate installation
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$BaseDir = Join-Path $env:USERPROFILE "dotbot"

# -----------------------------------------------------------------------------
# Detect context and run appropriate script
# -----------------------------------------------------------------------------

# Check if we're in the dotbot repository (for base installation)
$isInDotbotRepo = (Test-Path (Join-Path $ScriptDir "config.yml")) -and 
                  (Test-Path (Join-Path $ScriptDir "profiles"))

# Check if dotbot is already installed globally
$isDotbotInstalled = (Test-Path $BaseDir) -and 
                     (Test-Path (Join-Path $BaseDir "config.yml"))

# Check if current directory has .bot (for project setup)
$currentDir = Get-Location
$hasBotDir = Test-Path (Join-Path $currentDir ".bot")

# Determine what to do
if ($isInDotbotRepo -and -not $isDotbotInstalled) {
    # Running from dotbot repo and not yet installed globally
    Write-Host ""
    Write-Host "Detected: Running from dotbot repository" -ForegroundColor Cyan
    Write-Host "Action: Installing dotbot globally..." -ForegroundColor Yellow
    Write-Host ""
    
    $baseInstallScript = Join-Path $ScriptDir "scripts\base-install.ps1"
    if ($Arguments) {
        & $baseInstallScript @Arguments
    } else {
        & $baseInstallScript
    }
    
} elseif ($isInDotbotRepo -and $isDotbotInstalled) {
    # Running from dotbot repo but already installed - update it
    Write-Host ""
    Write-Host "Detected: dotbot is already installed globally" -ForegroundColor Cyan
    Write-Host "Action: Updating dotbot installation..." -ForegroundColor Yellow
    Write-Host ""
    
    $baseInstallScript = Join-Path $ScriptDir "scripts\base-install.ps1"
    if ($Arguments) {
        & $baseInstallScript @Arguments
    } else {
        & $baseInstallScript
    }
    
} elseif ($isDotbotInstalled -and -not $hasBotDir) {
    # dotbot is installed and we're in a project directory without .bot
    Write-Host ""
    Write-Host "Detected: Project directory without dotbot" -ForegroundColor Cyan
    Write-Host "Action: Initializing dotbot in current project..." -ForegroundColor Yellow
    Write-Host ""
    
    # Call dotbot init with any arguments
    if ($Arguments) {
        & dotbot init @Arguments
    } else {
        & dotbot init
    }
    
} elseif ($isDotbotInstalled -and $hasBotDir) {
    # dotbot is installed and project already has .bot
    Write-Host ""
    Write-Host "Detected: Project already has dotbot installed" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Use 'dotbot status' to check installation or 'dotbot update-project' to upgrade" -ForegroundColor Yellow
    Write-Host ""
    
}
    # Not in dotbot repo and dotbot not installed
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T" -ForegroundColor Blue
    Write-Host "    Installation" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ✗ dotbot is not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "  To install dotbot, run:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    cd ~" -ForegroundColor White
    Write-Host "    git clone https://github.com/andresharpe/dotbot" -ForegroundColor White
    Write-Host "    cd dotbot" -ForegroundColor White
    Write-Host "    .\init.ps1" -ForegroundColor White
    Write-Host ""
}
