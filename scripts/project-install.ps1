# =============================================================================
# dotbot Project Installation Script
# Installs dotbot into a project's codebase
# =============================================================================

[CmdletBinding()]
param(
    [string]$Profile,
    [bool]$WarpCommands,
    [bool]$DotbotCommands,
    [bool]$StandardsAsWarpRules,
    [switch]$ReInstall,
    [switch]$OverwriteAll,
    [switch]$OverwriteStandards,
    [switch]$OverwriteCommands,
    [switch]$DryRun
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

# Installed files tracking
$InstalledFiles = @()

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

function Initialize-Configuration {
    # Check if dotbot is installed
    if (-not (Test-Path $BaseDir)) {
        Write-FriendlyError "dotbot is not installed on this PC" `
            "Run 'dotbot install' or '.\scripts\base-install.ps1' first to set up dotbot globally" `
            -Fatal
    }
    
    # Load base configuration
    $baseConfig = Get-BaseConfig -BaseDir $BaseDir
    
    # Set effective values (command line overrides base config)
    $script:EffectiveProfile = if ($Profile) { $Profile } else { $baseConfig.Profile }
    $script:EffectiveWarpCommands = if ($PSBoundParameters.ContainsKey('WarpCommands')) { $WarpCommands } else { $baseConfig.WarpCommands }
    $script:EffectiveDotbotCommands = if ($PSBoundParameters.ContainsKey('DotbotCommands')) { $DotbotCommands } else { $baseConfig.DotbotCommands }
    $script:EffectiveStandardsAsWarpRules = if ($PSBoundParameters.ContainsKey('StandardsAsWarpRules')) { $StandardsAsWarpRules } else { $baseConfig.StandardsAsWarpRules }
    $script:EffectiveVersion = $baseConfig.Version
    
    # Validate configuration
    $validationResult = Test-ConfigValid `
        -WarpCommands $script:EffectiveWarpCommands `
        -DotbotCommands $script:EffectiveDotbotCommands `
        -StandardsAsWarpRules $script:EffectiveStandardsAsWarpRules `
        -Profile $script:EffectiveProfile `
        -BaseDir $BaseDir
    
    if (-not $validationResult) {
        # Validation may have disabled some features
        $script:EffectiveStandardsAsWarpRules = $false
    }
    
    Write-VerboseLog "Configuration:"
    Write-VerboseLog "  Profile: $script:EffectiveProfile"
    Write-VerboseLog "  Warp commands: $script:EffectiveWarpCommands"
    Write-VerboseLog "  Dotbot commands: $script:EffectiveDotbotCommands"
    Write-VerboseLog "  Standards as Warp Rules: $script:EffectiveStandardsAsWarpRules"
    Write-VerboseLog "  Version: $script:EffectiveVersion"
}

# -----------------------------------------------------------------------------
# Installation Functions
# -----------------------------------------------------------------------------

function Install-Standards {
    if (-not $DryRun) {
        Write-Status "Installing standards"
    }
    
    $standardsCount = 0
    $overwrite = $OverwriteAll -or $OverwriteStandards
    
    $files = Get-ProfileFiles -Profile $script:EffectiveProfile -BaseDir $BaseDir -Subfolder "standards"
    
    foreach ($file in $files) {
        $source = Get-ProfileFile -Profile $script:EffectiveProfile -RelativePath $file -BaseDir $BaseDir
        $dest = Join-Path $ProjectDir ".bot\$file"
        
        if ($source) {
            $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
            if ($installedFile) {
                $script:InstalledFiles += $installedFile
                $standardsCount++
            }
        }
    }
    
    if (-not $DryRun -and $standardsCount -gt 0) {
        Write-Success "Installed $standardsCount standards in .bot\standards"
    }
}

function Install-Workflows {
    if (-not $DryRun) {
        Write-Status "Installing workflows"
    }
    
    $workflowsCount = 0
    $overwrite = $OverwriteAll
    
    $files = Get-ProfileFiles -Profile $script:EffectiveProfile -BaseDir $BaseDir -Subfolder "workflows"
    
    foreach ($file in $files) {
        $source = Get-ProfileFile -Profile $script:EffectiveProfile -RelativePath $file -BaseDir $BaseDir
        $dest = Join-Path $ProjectDir ".bot\$file"
        
        if ($source) {
            $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
            if ($installedFile) {
                $script:InstalledFiles += $installedFile
                $workflowsCount++
            }
        }
    }
    
    if (-not $DryRun -and $workflowsCount -gt 0) {
        Write-Success "Installed $workflowsCount workflows in .bot\workflows"
    }
}

function Install-Commands {
    if (-not $script:EffectiveWarpCommands -and -not $script:EffectiveDotbotCommands) {
        return
    }
    
    if (-not $DryRun) {
        Write-Status "Installing commands"
    }
    
    $commandsCount = 0
    $overwrite = $OverwriteAll -or $OverwriteCommands
    
    $files = Get-ProfileFiles -Profile $script:EffectiveProfile -BaseDir $BaseDir -Subfolder "commands"
    
    foreach ($file in $files) {
        $source = Get-ProfileFile -Profile $script:EffectiveProfile -RelativePath $file -BaseDir $BaseDir
        
        # Install to Warp location
        if ($script:EffectiveWarpCommands) {
            $dest = Join-Path $ProjectDir ".warp\commands\dotbot\$file"
            if ($source) {
                $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
                if ($installedFile) {
                    $script:InstalledFiles += $installedFile
                    $commandsCount++
                }
            }
        }
        
        # Install to .bot location  
        if ($script:EffectiveDotbotCommands) {
            $dest = Join-Path $ProjectDir ".bot\commands\$file"
            if ($source) {
                $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
                if ($installedFile) {
                    $script:InstalledFiles += $installedFile
                    $commandsCount++
                }
            }
        }
    }
    
    if (-not $DryRun -and $commandsCount -gt 0) {
        Write-Success "Installed $commandsCount commands"
    }
}


function Show-WorkflowMap {
    Write-Host ""
    Write-Host "  WORKFLOW" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  📋 Plan → 🔍 Shape → 📝 Specify → ✂️ Tasks → ⚡ Implement → ✅ Verify" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    /plan-product     " -NoNewline -ForegroundColor Yellow
    Write-Host "Define product vision & roadmap" -ForegroundColor White
    Write-Host "    /shape-spec       " -NoNewline -ForegroundColor Yellow
    Write-Host "Research and scope features" -ForegroundColor White
    Write-Host "    /write-spec       " -NoNewline -ForegroundColor Yellow
    Write-Host "Write technical specifications" -ForegroundColor White
    Write-Host "    /create-tasks     " -NoNewline -ForegroundColor Yellow
    Write-Host "Break specs into tasks" -ForegroundColor White
    Write-Host "    /implement-tasks  " -NoNewline -ForegroundColor Yellow
    Write-Host "Execute with verification" -ForegroundColor White
    Write-Host ""
}

function Show-InstallationSummary {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  ✓ Installation Complete!" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  📦 Files:   " -NoNewline -ForegroundColor Yellow
    Write-Host "$($script:InstalledFiles.Count) installed" -ForegroundColor White
    Write-Host "  🎯 Profile: " -NoNewline -ForegroundColor Yellow
    Write-Host "$script:EffectiveProfile" -ForegroundColor White
    Write-Host "  📌 Version: " -NoNewline -ForegroundColor Yellow
    Write-Host "$script:EffectiveVersion" -ForegroundColor White
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    
    # Show workflow map
    Show-WorkflowMap
    
    Write-Host "  NEXT STEPS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    • " -NoNewline -ForegroundColor Yellow
    Write-Host "Start with /plan-product to define your vision" -ForegroundColor White
    Write-Host "    • " -NoNewline -ForegroundColor Yellow
    Write-Host "Review standards in .bot\standards" -ForegroundColor White
    if ($script:EffectiveWarpCommands) {
        Write-Host "    • " -NoNewline -ForegroundColor Yellow
        Write-Host "All commands available as Warp slash commands" -ForegroundColor White
    }
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T" -ForegroundColor Blue
Write-Host "    Project Installation" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

if ($DryRun) {
    Write-Warning "DRY RUN MODE - No changes will be made"
    Write-Host ""
}

# Initialize configuration
Initialize-Configuration

# Handle re-install
if ($ReInstall -and -not $DryRun) {
    Write-Warning "Re-installing dotbot (removing existing files)..."
    
    $pathsToRemove = @(
        (Join-Path $ProjectDir ".bot"),
        (Join-Path $ProjectDir ".warp\commands\dotbot")
    )
    
    foreach ($path in $pathsToRemove) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            Write-VerboseLog "Removed: $path"
        }
    }
}

# Install components
Install-Standards
Install-Workflows
Install-Commands

# Create state file
if (-not $DryRun) {
    $stateFile = Join-Path $ProjectDir ".bot\.dotbot-state.json"
    $stateData = @{
        version = $script:EffectiveVersion
        profile = $script:EffectiveProfile
        installed_at = (Get-Date -Format "o")
        warp_commands = $script:EffectiveWarpCommands
        dotbot_commands = $script:EffectiveDotbotCommands
        standards_as_warp_rules = $script:EffectiveStandardsAsWarpRules
    }
    $stateData | ConvertTo-Json | Set-Content $stateFile
}

# Show summary
if (-not $DryRun) {
    Show-InstallationSummary
}

