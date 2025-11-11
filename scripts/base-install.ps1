# =============================================================================
# dotbot Base Installation Script
# Installs dotbot from local repository or GitHub to ~\dotbot
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Verbose,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Installation paths
$BaseDir = Join-Path $env:USERPROFILE "dotbot"
$ScriptDir = $PSScriptRoot
$SourceDir = Split-Path -Parent $ScriptDir

# Import common functions
Import-Module (Join-Path $ScriptDir "Common-Functions.psm1") -Force

# Set script-level verbose flag
$script:Verbose = $Verbose.IsPresent

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Test-GitInstalled {
    try {
        git --version | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Install-FromLocal {
    Write-Status "Installing dotbot from local repository..."
    
    if ($DryRun) {
        Write-Verbose "Would copy files from: $SourceDir"
        Write-Verbose "Would copy to: $BaseDir"
        return
    }
    
    # Create base directory
    if (-not (Test-Path $BaseDir)) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    }
    
    # Copy all files except .git
    $itemsToCopy = Get-ChildItem -Path $SourceDir -Exclude ".git"
    
    foreach ($item in $itemsToCopy) {
        $dest = Join-Path $BaseDir $item.Name
        
        if ($item.PSIsContainer) {
            Write-Verbose "Copying directory: $($item.Name)"
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
        } else {
            Write-Verbose "Copying file: $($item.Name)"
            Copy-Item -Path $item.FullName -Destination $dest -Force
        }
    }
    
    Write-Success "dotbot installed to: $BaseDir"
}

function Install-FromGitHub {
    param([string]$RepoUrl)
    
    if (-not (Test-GitInstalled)) {
        Write-Error "Git is not installed. Please install Git or run from the local repository."
        exit 1
    }
    
    Write-Status "Installing dotbot from GitHub: $RepoUrl"
    
    if ($DryRun) {
        Write-Verbose "Would clone from: $RepoUrl"
        Write-Verbose "Would clone to: $BaseDir"
        return
    }
    
    # Remove existing directory if it exists
    if (Test-Path $BaseDir) {
        Write-Warning "Removing existing installation at: $BaseDir"
        Remove-Item -Path $BaseDir -Recurse -Force
    }
    
    # Clone repository
    git clone $RepoUrl $BaseDir
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to clone repository"
        exit 1
    }
    
    Write-Success "dotbot installed to: $BaseDir"
}

function Show-PostInstallInstructions {
    Write-Host ""
    Write-Success "dotbot installation complete!"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Navigate to your project directory"
    Write-Host "  2. Run: ~\dotbot\scripts\project-install.ps1"
    Write-Host ""
    Write-Host "For more information, see: $BaseDir\README.md" -ForegroundColor Gray
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host "===================================" -ForegroundColor Cyan
Write-Host "   dotbot Base Installation" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Warning "DRY RUN MODE - No changes will be made"
    Write-Host ""
}

# Check if we're running from a local repository
if (Test-Path (Join-Path $SourceDir ".git")) {
    Write-Verbose "Detected local git repository"
    Install-FromLocal
} elseif (Test-Path (Join-Path $SourceDir "config.yml")) {
    Write-Verbose "Detected local dotbot installation"
    Install-FromLocal
} else {
    # Could add GitHub installation here in the future
    Write-Error "Please run this script from the dotbot repository directory"
    exit 1
}

if (-not $DryRun) {
    Show-PostInstallInstructions
}
