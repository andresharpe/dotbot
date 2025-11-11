# =============================================================================
# dotbot Update Script
# Updates the base dotbot installation from repository
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Paths
$BaseDir = Join-Path $env:USERPROFILE "dotbot"
$ScriptDir = $PSScriptRoot
$SourceDir = Split-Path -Parent $ScriptDir

# Import common functions
Import-Module (Join-Path $ScriptDir "Common-Functions.psm1") -Force

# Set script-level verbose flag from CmdletBinding
$script:Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# -----------------------------------------------------------------------------
# Main Update
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "   dotbot Update" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Warning "DRY RUN MODE - No changes will be made"
    Write-Host ""
}

# Check if dotbot is installed
if (-not (Test-Path $BaseDir)) {
    Write-FriendlyError "dotbot is not installed on this PC" `
        "Run 'dotbot install' or '.\scripts\base-install.ps1' first" `
        -Fatal
}

# Get current version
$currentVersion = "Unknown"
$configPath = Join-Path $BaseDir "config.yml"
if (Test-Path $configPath) {
    $currentVersion = Get-ConfigValue -ConfigPath $configPath -Key "version"
}

Write-Host "Current version: $currentVersion" -ForegroundColor Cyan
Write-Host ""

# Check if we're in a git repository
$isGitRepo = Test-Path (Join-Path $BaseDir ".git")

if ($isGitRepo) {
    # Git-based update
    Write-Status "Updating from git repository..."
    
    if ($DryRun) {
        Write-VerboseLog "Would run: git pull"
        Write-Host ""
        Write-Host "Would update dotbot from git" -ForegroundColor Yellow
        return
    }
    
    Set-Location $BaseDir
    $output = git pull 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -ne 0) {
        Write-FriendlyError "Failed to update from git" `
            "Check git status in $BaseDir and resolve any conflicts" `
            -Fatal
    }
    
    if ($output -like "*Already up to date*") {
        Write-Success "dotbot is already up to date!"
    } else {
        Write-Success "dotbot updated successfully!"
        
        # Get new version
        $newVersion = Get-ConfigValue -ConfigPath $configPath -Key "version"
        if ($newVersion -and $newVersion -ne $currentVersion) {
            Write-Host ""
            Write-Host "Updated: $currentVersion → $newVersion" -ForegroundColor Green
        }
    }
} else {
    # Manual/local update
    Write-Status "Updating from local repository..."
    
    if (-not (Test-Path $SourceDir)) {
        Write-FriendlyError "Cannot find source directory" `
            "Run this script from the dotbot repository, or convert to git: cd $BaseDir && git init" `
            -Fatal
    }
    
    if ($DryRun) {
        Write-VerboseLog "Would copy files from: $SourceDir"
        Write-VerboseLog "Would copy to: $BaseDir"
        Write-Host ""
        Write-Host "Would update dotbot from local repository" -ForegroundColor Yellow
        return
    }
    
    # Copy all files except .git
    $itemsToCopy = Get-ChildItem -Path $SourceDir -Exclude ".git"
    
    foreach ($item in $itemsToCopy) {
        $dest = Join-Path $BaseDir $item.Name
        
        # Skip if source and destination are the same
        if ($item.FullName -eq $dest) {
            Write-VerboseLog "Skipping (same location): $($item.Name)"
            continue
        }
        
        if ($item.PSIsContainer) {
            Write-VerboseLog "Copying directory: $($item.Name)"
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
        } else {
            Write-VerboseLog "Copying file: $($item.Name)"
            Copy-Item -Path $item.FullName -Destination $dest -Force
        }
    }
    
    Write-Success "dotbot updated from local repository!"
    
    # Get new version
    $newVersion = Get-ConfigValue -ConfigPath $configPath -Key "version"
    if ($newVersion -and $newVersion -ne $currentVersion) {
        Write-Host ""
        Write-Host "Updated: $currentVersion → $newVersion" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  • Run 'dotbot upgrade-project' in your projects to update them"
Write-Host "  • Review changelog for any breaking changes"
Write-Host ""
