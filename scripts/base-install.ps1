# =============================================================================
# dotbot Base Installation Script
# Installs dotbot from local repository or GitHub to ~\dotbot
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Installation paths
$BaseDir = Join-Path $env:USERPROFILE "dotbot"
$ScriptDir = $PSScriptRoot
$SourceDir = Split-Path -Parent $ScriptDir

# Import common functions
Import-Module (Join-Path $ScriptDir "Common-Functions.psm1") -Force

# Set script-level verbose flag from CmdletBinding
$script:Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

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
        Write-VerboseLog "Would copy files from: $SourceDir"
        Write-VerboseLog "Would copy to: $BaseDir"
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
            Write-VerboseLog "Copying directory: $($item.Name)"
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
        } else {
            Write-VerboseLog "Copying file: $($item.Name)"
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
        Write-VerboseLog "Would clone from: $RepoUrl"
        Write-VerboseLog "Would clone to: $BaseDir"
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

function Add-DotbotToPath {
    $binDir = Join-Path $BaseDir "bin"
    
    if ($DryRun) {
        Write-VerboseLog "Would add to PATH: $binDir"
        return
    }
    
    # Get current user PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    # Check if already in PATH
    if ($currentPath -like "*$binDir*") {
        Write-VerboseLog "dotbot bin directory already in PATH"
        return
    }
    
    Write-Status "Adding dotbot to PATH..."
    
    # Add to PATH
    $newPath = "$binDir;$currentPath"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    
    # Update current session
    $env:Path = "$binDir;$env:Path"
    
    Write-Success "Added to PATH: $binDir"
}

function Show-PostInstallInstructions {
    Write-Host ""
    Write-Success "dotbot installation complete!"
    Write-Host ""
    Write-Host "Global 'dotbot' command is now available!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Restart your terminal (or run: refreshenv)"
    Write-Host "  2. Navigate to your project directory"
    Write-Host "  3. Run: dotbot init"
    Write-Host ""
    Write-Host "Quick commands:" -ForegroundColor Yellow
    Write-Host "  dotbot help      - Show all commands"
    Write-Host "  dotbot status    - Check installation status"
    Write-Host "  dotbot init      - Add dotbot to a project"
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
    Write-VerboseLog "Detected local git repository"
    Install-FromLocal
} elseif (Test-Path (Join-Path $SourceDir "config.yml")) {
    Write-VerboseLog "Detected local dotbot installation"
    Install-FromLocal
} else {
    # Could add GitHub installation here in the future
    Write-Error "Please run this script from the dotbot repository directory"
    exit 1
}

if (-not $DryRun) {
    # Add dotbot to PATH
    Add-DotbotToPath
    
    # Show instructions
    Show-PostInstallInstructions
}

