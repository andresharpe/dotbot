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
$BaseDir = Join-Path $HOME "dotbot"
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
    
    # Use cross-platform Remove-FromPath function
    Remove-FromPath -Directory $binDir -DryRun:$DryRun
}

function Uninstall-Project {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T" -ForegroundColor Blue
    Write-Host "    Project Uninstall" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    $botDir = Join-Path $ProjectDir ".bot"
    $warpCommandsDir = Join-Path $ProjectDir ".warp\commands\dotbot"
    
    if (-not (Test-Path $botDir)) {
        Write-Host "  ✗ This project doesn't have dotbot installed" -ForegroundColor Red
        Write-Host ""
        exit 0
    }
    
    # Show what will be removed
    Write-Host "  Will remove:" -ForegroundColor Yellow
    if (Test-Path $botDir) {
        Write-Host "    • " -NoNewline -ForegroundColor Yellow
        Write-Host ".bot/ directory" -ForegroundColor White
    }
    if (Test-Path $warpCommandsDir) {
        Write-Host "    • " -NoNewline -ForegroundColor Yellow
        Write-Host ".warp/commands/dotbot/ directory" -ForegroundColor White
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
    Write-Status "Uninstalling..."
    
    # Remove directories
    if (Test-Path $botDir) {
        Remove-Item -Path $botDir -Recurse -Force
        Write-Success "Removed .bot/"
    }
    
    if (Test-Path $warpCommandsDir) {
        Remove-Item -Path $warpCommandsDir -Recurse -Force
        Write-Success "Removed .warp/commands/dotbot/"
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ✓ Project Uninstall Complete!" -ForegroundColor Blue
    Write-Host ""
}

function Uninstall-Global {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T" -ForegroundColor Blue
    Write-Host "    Global Uninstall" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    if (-not (Test-Path $BaseDir)) {
        Write-Host "  ✗ dotbot is not installed globally" -ForegroundColor Red
        Write-Host ""
        exit 0
    }
    
    $configPath = Join-Path $BaseDir "config.yml"
    
    # Show what will be removed
    Write-Host "  Will remove:" -ForegroundColor Yellow
    Write-Host "    • " -NoNewline -ForegroundColor Yellow
    Write-Host "$BaseDir directory" -ForegroundColor White
    Write-Host "    • " -NoNewline -ForegroundColor Yellow
    Write-Host "dotbot from PATH" -ForegroundColor White
    if ($KeepConfig -and (Test-Path $configPath)) {
        Write-Host ""
        Write-Host "  Will preserve:" -ForegroundColor Blue
        Write-Host "    • " -NoNewline -ForegroundColor Yellow
        Write-Host "config.yml (backed up to ~/dotbot-config-backup.yml)" -ForegroundColor White
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
    Write-Status "Uninstalling..."
    
    # Backup config if requested
    if ($KeepConfig -and (Test-Path $configPath)) {
        $backupPath = Join-Path $HOME "dotbot-config-backup.yml"
        Copy-Item -Path $configPath -Destination $backupPath -Force
        Write-Success "Backed up config to: $backupPath"
    }
    
    # Remove from PATH
    Remove-DotbotFromPath
    
    # Remove directory
    Remove-Item -Path $BaseDir -Recurse -Force
    Write-Success "Removed $BaseDir"
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ✓ Global Uninstall Complete!" -ForegroundColor Blue
    Write-Host ""
    
    if ($KeepConfig) {
        Write-Host "  Config backup: ~/dotbot-config-backup.yml" -ForegroundColor Gray
        Write-Host "  Restore with: Move-Item ~/dotbot-config-backup.yml ~/dotbot/config.yml" -ForegroundColor Gray
        Write-Host ""
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Validate parameters
if (-not $Project -and -not $Global) {
    Write-Host ""
    Write-Host "❌ Error: This command is for internal use only" -ForegroundColor Red
    Write-Host ""
    Write-Host "Use these commands instead:" -ForegroundColor Yellow
    Write-Host "  dotbot remove-project             # Remove from current project"
    Write-Host "  dotbot uninstall                  # Remove dotbot completely"
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
