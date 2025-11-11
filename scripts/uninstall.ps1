# =============================================================================
# dotbot Uninstall Script
# Removes dotbot from projects or globally
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Project,
    [switch]$Global,
    [switch]$KeepConfig,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Paths
$BaseDir = Join-Path $env:USERPROFILE "dotbot"
$ProjectDir = Get-Location
$ScriptDir = $PSScriptRoot

# Import common functions
$commonFunctionsPath = Join-Path $ScriptDir "Common-Functions.psm1"
if (Test-Path $commonFunctionsPath) {
    Import-Module $commonFunctionsPath -Force
}

# Set script-level verbose flag from CmdletBinding
$script:Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Remove-DotbotFromPath {
    $binDir = Join-Path $BaseDir "bin"
    
    if ($DryRun) {
        Write-Host "Would remove from PATH: $binDir" -ForegroundColor Yellow
        return
    }
    
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    if ($currentPath -like "*$binDir*") {
        Write-Host "→ Removing from PATH..." -ForegroundColor Cyan
        $newPath = ($currentPath -split ';' | Where-Object { $_ -ne $binDir }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = ($env:Path -split ';' | Where-Object { $_ -ne $binDir }) -join ';'
        Write-Host "✓ Removed from PATH" -ForegroundColor Green
    }
}

function Uninstall-Project {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "   dotbot Project Uninstall" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    
    $botDir = Join-Path $ProjectDir ".bot"
    $warpCommandsDir = Join-Path $ProjectDir ".warp\commands\dotbot"
    
    if (-not (Test-Path $botDir)) {
        Write-Host "❌ This project doesn't have dotbot installed" -ForegroundColor Red
        Write-Host ""
        exit 0
    }
    
    # Show what will be removed
    Write-Host "Will remove:" -ForegroundColor Yellow
    if (Test-Path $botDir) {
        Write-Host "  • .bot/ directory"
    }
    if (Test-Path $warpCommandsDir) {
        Write-Host "  • .warp/commands/dotbot/ directory"
    }
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "DRY RUN - No changes made" -ForegroundColor Yellow
        Write-Host ""
        return
    }
    
    # Confirm
    Write-Host "Are you sure you want to uninstall dotbot from this project? (y/N): " -NoNewline -ForegroundColor Yellow
    $confirmation = Read-Host
    
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host ""
        Write-Host "Cancelled" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    
    Write-Host ""
    Write-Host "→ Uninstalling..." -ForegroundColor Cyan
    
    # Remove directories
    if (Test-Path $botDir) {
        Remove-Item -Path $botDir -Recurse -Force
        Write-Host "✓ Removed .bot/" -ForegroundColor Green
    }
    
    if (Test-Path $warpCommandsDir) {
        Remove-Item -Path $warpCommandsDir -Recurse -Force
        Write-Host "✓ Removed .warp/commands/dotbot/" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "✓ dotbot uninstalled from project" -ForegroundColor Green
    Write-Host ""
}

function Uninstall-Global {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "   dotbot Global Uninstall" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-Path $BaseDir)) {
        Write-Host "❌ dotbot is not installed globally" -ForegroundColor Red
        Write-Host ""
        exit 0
    }
    
    $configPath = Join-Path $BaseDir "config.yml"
    
    # Show what will be removed
    Write-Host "Will remove:" -ForegroundColor Yellow
    Write-Host "  • $BaseDir directory"
    Write-Host "  • dotbot from PATH"
    if ($KeepConfig -and (Test-Path $configPath)) {
        Write-Host ""
        Write-Host "Will preserve:" -ForegroundColor Green
        Write-Host "  • config.yml (backed up to ~/dotbot-config-backup.yml)"
    }
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "DRY RUN - No changes made" -ForegroundColor Yellow
        Write-Host ""
        return
    }
    
    # Confirm
    Write-Host "Are you sure you want to uninstall dotbot globally? (y/N): " -NoNewline -ForegroundColor Yellow
    $confirmation = Read-Host
    
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host ""
        Write-Host "Cancelled" -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    
    Write-Host ""
    Write-Host "→ Uninstalling..." -ForegroundColor Cyan
    
    # Backup config if requested
    if ($KeepConfig -and (Test-Path $configPath)) {
        $backupPath = Join-Path $env:USERPROFILE "dotbot-config-backup.yml"
        Copy-Item -Path $configPath -Destination $backupPath -Force
        Write-Host "✓ Backed up config to: $backupPath" -ForegroundColor Green
    }
    
    # Remove from PATH
    Remove-DotbotFromPath
    
    # Remove directory
    Remove-Item -Path $BaseDir -Recurse -Force
    Write-Host "✓ Removed $BaseDir" -ForegroundColor Green
    
    Write-Host ""
    Write-Host "✓ dotbot uninstalled globally" -ForegroundColor Green
    Write-Host ""
    
    if ($KeepConfig) {
        Write-Host "Config backup: ~/dotbot-config-backup.yml" -ForegroundColor Gray
        Write-Host "Restore with: Move-Item ~/dotbot-config-backup.yml ~/dotbot/config.yml" -ForegroundColor Gray
        Write-Host ""
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Validate parameters
if (-not $Project -and -not $Global) {
    Write-Host ""
    Write-Host "❌ Please specify --Project or --Global" -ForegroundColor Red
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  dotbot uninstall --Project        # Remove from current project"
    Write-Host "  dotbot uninstall --Global         # Remove dotbot completely"
    Write-Host "  dotbot uninstall --Global --KeepConfig  # Keep config backup"
    Write-Host ""
    exit 1
}

if ($Project -and $Global) {
    Write-Host ""
    Write-Host "❌ Cannot specify both --Project and --Global" -ForegroundColor Red
    Write-Host ""
    exit 1
}

if ($Project) {
    Uninstall-Project
} else {
    Uninstall-Global
}
