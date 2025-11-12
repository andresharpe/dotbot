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
$BaseDir = Join-Path $HOME "dotbot"
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
    
    # Check if source and destination are the same
    $resolvedSource = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
    $resolvedBase = if (Test-Path $BaseDir) { (Resolve-Path $BaseDir).Path.TrimEnd('\', '/') } else { $null }
    
    if ($resolvedBase -and ($resolvedSource -eq $resolvedBase)) {
        Write-VerboseLog "Already running from target installation directory: $BaseDir"
        Write-Success "dotbot is already installed at: $BaseDir"
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
        Write-FriendlyError "Git is not installed" `
            "Install Git from https://git-scm.com or run this script from a local dotbot repository" `
            -Fatal
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
        Write-FriendlyError "Failed to clone repository from GitHub" `
            "Check your internet connection and repository URL, or clone manually with: git clone $RepoUrl $BaseDir" `
            -Fatal
    }
    
    Write-Success "dotbot installed to: $BaseDir"
}

function Add-DotbotToPath {
    $binDir = Join-Path $BaseDir "bin"
    
    # Use cross-platform Add-ToPath function
    Add-ToPath -Directory $binDir -DryRun:$DryRun
    
    # Set executable permissions on Unix
    if (-not $DryRun) {
        $dotbotScript = Join-Path $binDir "dotbot.ps1"
        if (Test-Path $dotbotScript) {
            Set-ExecutablePermission -FilePath $dotbotScript
        }
    }
}

function Show-PostInstallInstructions {
    $platformName = Get-PlatformName
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ✓ Installation Complete!" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  Platform: $platformName" -ForegroundColor Gray
    Write-Host "  Global 'dotbot' command is now available!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  NEXT STEPS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    1. " -NoNewline -ForegroundColor Yellow
    
    Initialize-PlatformVariables
    if ($script:IsWindows) {
        Write-Host "Restart your terminal" -ForegroundColor White
    } else {
        Write-Host "Restart your terminal or run: source ~/.bashrc (or ~/.zshrc)" -ForegroundColor White
    }
    
    Write-Host "    2. " -NoNewline -ForegroundColor Yellow
    Write-Host "Navigate to your project directory" -ForegroundColor White
    Write-Host "    3. " -NoNewline -ForegroundColor Yellow
    Write-Host "Run: dotbot init" -ForegroundColor White
    Write-Host ""
    Write-Host "  QUICK COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    dotbot help      " -NoNewline -ForegroundColor Yellow
    Write-Host "Show all commands" -ForegroundColor White
    Write-Host "    dotbot status    " -NoNewline -ForegroundColor Yellow
    Write-Host "Check installation status" -ForegroundColor White
    Write-Host "    dotbot init      " -NoNewline -ForegroundColor Yellow
    Write-Host "Add dotbot to a project" -ForegroundColor White
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T" -ForegroundColor Blue
Write-Host "    Base Installation" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

if ($DryRun) {
    Write-Warning "DRY RUN MODE - No changes will be made"
    Write-Host ""
}

# Check PowerShell version
if (-not (Test-PowerShellVersion)) {
    Write-Host ""
    exit 1
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
    Write-FriendlyError "Not running from dotbot repository directory" `
        "Navigate to your dotbot repository and run: .\scripts\base-install.ps1" `
        -Fatal
}

if (-not $DryRun) {
    # Add dotbot to PATH
    Add-DotbotToPath
    
    # Show instructions
    Show-PostInstallInstructions
}

