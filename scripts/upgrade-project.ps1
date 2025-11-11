# =============================================================================
# dotbot Project Upgrade Script
# Upgrades a project to the latest dotbot version
# =============================================================================

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$PreserveCustomizations
)

$ErrorActionPreference = "Stop"

# Paths
$BaseDir = Join-Path $env:USERPROFILE "dotbot"
$ProjectDir = Get-Location
$ScriptDir = $PSScriptRoot

# Import common functions
Import-Module (Join-Path $ScriptDir "Common-Functions.psm1") -Force

# Set script-level verbose flag from CmdletBinding
$script:Verbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# -----------------------------------------------------------------------------
# Main Upgrade
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "   dotbot Project Upgrade" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Warning "DRY RUN MODE - No changes will be made"
    Write-Host ""
}

# Check if dotbot is installed
if (-not (Test-Path $BaseDir)) {
    Write-FriendlyError "dotbot is not installed on this PC" `
        "Run 'dotbot install' first" `
        -Fatal
}

# Check if project has dotbot
$botDir = Join-Path $ProjectDir ".bot"
if (-not (Test-Path $botDir)) {
    Write-FriendlyError "This project doesn't have dotbot installed" `
        "Run 'dotbot init' to initialize dotbot in this project" `
        -Fatal
}

# Get versions
$baseVersion = "Unknown"
$projectVersion = "Unknown"

$baseConfigPath = Join-Path $BaseDir "config.yml"
if (Test-Path $baseConfigPath) {
    $baseVersion = Get-ConfigValue -ConfigPath $baseConfigPath -Key "version"
}

$projectStatePath = Join-Path $botDir ".dotbot-state.json"
if (Test-Path $projectStatePath) {
    $state = Get-Content $projectStatePath -Raw | ConvertFrom-Json
    $projectVersion = $state.version
}

Write-Host "Base dotbot version: $baseVersion" -ForegroundColor Cyan
Write-Host "Project dotbot version: $projectVersion" -ForegroundColor Cyan
Write-Host ""

if ($baseVersion -eq $projectVersion) {
    Write-Success "Project is already up to date!"
    Write-Host ""
    exit 0
}

Write-Status "Upgrading project..."

if ($PreserveCustomizations) {
    Write-Host ""
    Write-Warning "Preserving customizations - only updating non-customized files"
    Write-Host ""
    Write-Host "Files that will NOT be updated:" -ForegroundColor Yellow
    Write-Host "  • Any file modified after initial installation"
    Write-Host "  • Custom standards in .bot/standards/custom/"
    Write-Host ""
}

if ($DryRun) {
    Write-Host "Would perform upgrade:" -ForegroundColor Yellow
    Write-Host "  • Update workflows in .bot/workflows/"
    Write-Host "  • Update standards in .bot/standards/"
    Write-Host "  • Update commands in .warp/commands/dotbot/ or .bot/commands/"
    if (-not $PreserveCustomizations) {
        Write-Host "  • Overwrite existing files"
    }
    Write-Host ""
    return
}

# Backup current installation
$backupDir = Join-Path $ProjectDir ".bot-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Status "Creating backup at: $backupDir"
Copy-Item -Path $botDir -Destination $backupDir -Recurse -Force

# Run project-install with appropriate flags
$installParams = @{
    ReInstall = $true
}

if (-not $PreserveCustomizations) {
    $installParams['OverwriteAll'] = $true
}

Write-Status "Running project installation..."
Write-Host ""

& (Join-Path $ScriptDir "project-install.ps1") @installParams

# Create/update state file
$stateData = @{
    version = $baseVersion
    upgraded_at = (Get-Date -Format "o")
    previous_version = $projectVersion
    backup_location = $backupDir
}

$stateData | ConvertTo-Json | Set-Content $projectStatePath

Write-Host ""
Write-Success "Project upgraded successfully!"
Write-Host ""
Write-Host "Upgraded: $projectVersion → $baseVersion" -ForegroundColor Green
Write-Host ""
Write-Host "Backup location: $backupDir" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  • Review updated standards and workflows"
Write-Host "  • Test your dotbot commands"
Write-Host "  • Remove backup if everything works: Remove-Item '$backupDir' -Recurse"
Write-Host ""
