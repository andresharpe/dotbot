# =============================================================================
# dotbot Project Installation Script
# Installs dotbot into a project's codebase
# =============================================================================

[CmdletBinding()]
param(
    [string]$Profile,
    [bool]$ClaudeCodeCommands,
    [bool]$UseClaudeCodeSubagents,
    [bool]$DotbotCommands,
    [bool]$StandardsAsClaudeCodeSkills,
    [switch]$ReInstall,
    [switch]$OverwriteAll,
    [switch]$OverwriteStandards,
    [switch]$OverwriteCommands,
    [switch]$OverwriteAgents,
    [switch]$DryRun,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Paths
$BaseDir = Join-Path $env:USERPROFILE "dotbot"
$ProjectDir = Get-Location
$ScriptDir = $PSScriptRoot

# Import common functions
Import-Module (Join-Path $ScriptDir "Common-Functions.psm1") -Force

# Set script-level verbose flag
$script:Verbose = $Verbose.IsPresent

# Installed files tracking
$InstalledFiles = @()

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

function Initialize-Configuration {
    # Check if dotbot is installed
    if (-not (Test-Path $BaseDir)) {
        Write-Error "dotbot is not installed. Please run base-install.ps1 first."
        exit 1
    }
    
    # Load base configuration
    $baseConfig = Get-BaseConfig -BaseDir $BaseDir
    
    # Set effective values (command line overrides base config)
    $script:EffectiveProfile = if ($Profile) { $Profile } else { $baseConfig.Profile }
    $script:EffectiveClaudeCodeCommands = if ($PSBoundParameters.ContainsKey('ClaudeCodeCommands')) { $ClaudeCodeCommands } else { $baseConfig.ClaudeCodeCommands }
    $script:EffectiveUseClaudeCodeSubagents = if ($PSBoundParameters.ContainsKey('UseClaudeCodeSubagents')) { $UseClaudeCodeSubagents } else { $baseConfig.UseClaudeCodeSubagents }
    $script:EffectiveDotbotCommands = if ($PSBoundParameters.ContainsKey('DotbotCommands')) { $DotbotCommands } else { $baseConfig.DotbotCommands }
    $script:EffectiveStandardsAsClaudeCodeSkills = if ($PSBoundParameters.ContainsKey('StandardsAsClaudeCodeSkills')) { $StandardsAsClaudeCodeSkills } else { $baseConfig.StandardsAsClaudeCodeSkills }
    $script:EffectiveVersion = $baseConfig.Version
    
    # Validate configuration
    $validationResult = Test-ConfigValid `
        -ClaudeCodeCommands $script:EffectiveClaudeCodeCommands `
        -UseClaudeCodeSubagents $script:EffectiveUseClaudeCodeSubagents `
        -DotbotCommands $script:EffectiveDotbotCommands `
        -StandardsAsClaudeCodeSkills $script:EffectiveStandardsAsClaudeCodeSkills `
        -Profile $script:EffectiveProfile `
        -BaseDir $BaseDir
    
    if (-not $validationResult) {
        # Validation may have disabled some features
        $script:EffectiveUseClaudeCodeSubagents = $false
        $script:EffectiveStandardsAsClaudeCodeSkills = $false
    }
    
    Write-Verbose "Configuration:"
    Write-Verbose "  Profile: $script:EffectiveProfile"
    Write-Verbose "  Claude Code commands: $script:EffectiveClaudeCodeCommands"
    Write-Verbose "  Use Claude Code subagents: $script:EffectiveUseClaudeCodeSubagents"
    Write-Verbose "  Dotbot commands: $script:EffectiveDotbotCommands"
    Write-Verbose "  Standards as Claude Code Skills: $script:EffectiveStandardsAsClaudeCodeSkills"
    Write-Verbose "  Version: $script:EffectiveVersion"
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
        $dest = Join-Path $ProjectDir "dotbot\$file"
        
        if ($source) {
            $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
            if ($installedFile) {
                $script:InstalledFiles += $installedFile
                $standardsCount++
            }
        }
    }
    
    if (-not $DryRun -and $standardsCount -gt 0) {
        Write-Success "Installed $standardsCount standards in dotbot\standards"
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
        $dest = Join-Path $ProjectDir "dotbot\$file"
        
        if ($source) {
            $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
            if ($installedFile) {
                $script:InstalledFiles += $installedFile
                $workflowsCount++
            }
        }
    }
    
    if (-not $DryRun -and $workflowsCount -gt 0) {
        Write-Success "Installed $workflowsCount workflows in dotbot\workflows"
    }
}

function Install-Commands {
    if (-not $script:EffectiveClaudeCodeCommands -and -not $script:EffectiveDotbotCommands) {
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
        
        # Install to Claude Code location
        if ($script:EffectiveClaudeCodeCommands) {
            $dest = Join-Path $ProjectDir ".claude\commands\dotbot\$file"
            if ($source) {
                $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
                if ($installedFile) {
                    $script:InstalledFiles += $installedFile
                    $commandsCount++
                }
            }
        }
        
        # Install to dotbot location
        if ($script:EffectiveDotbotCommands) {
            $dest = Join-Path $ProjectDir "dotbot\commands\$file"
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

function Install-Agents {
    if (-not $script:EffectiveUseClaudeCodeSubagents) {
        return
    }
    
    if (-not $DryRun) {
        Write-Status "Installing agents"
    }
    
    $agentsCount = 0
    $overwrite = $OverwriteAll -or $OverwriteAgents
    
    $files = Get-ProfileFiles -Profile $script:EffectiveProfile -BaseDir $BaseDir -Subfolder "agents"
    
    foreach ($file in $files) {
        $source = Get-ProfileFile -Profile $script:EffectiveProfile -RelativePath $file -BaseDir $BaseDir
        $dest = Join-Path $ProjectDir ".claude\agents\dotbot\$file"
        
        if ($source) {
            $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
            if ($installedFile) {
                $script:InstalledFiles += $installedFile
                $agentsCount++
            }
        }
    }
    
    if (-not $DryRun -and $agentsCount -gt 0) {
        Write-Success "Installed $agentsCount agents in .claude\agents\dotbot"
    }
}

function Show-InstallationSummary {
    Write-Host ""
    Write-Success "dotbot installation complete!"
    Write-Host ""
    Write-Host "Installed files: $($script:InstalledFiles.Count)" -ForegroundColor Cyan
    Write-Host "Profile: $script:EffectiveProfile" -ForegroundColor Cyan
    Write-Host "Version: $script:EffectiveVersion" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  • Review the standards in dotbot\standards"
    Write-Host "  • Check the workflows in dotbot\workflows"
    if ($script:EffectiveClaudeCodeCommands) {
        Write-Host "  • Use Claude Code commands in .claude\commands\dotbot"
    }
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Main Installation
# -----------------------------------------------------------------------------

Write-Host ""
Write-Host "===================================" -ForegroundColor Cyan
Write-Host "   dotbot Project Installation" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
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
        (Join-Path $ProjectDir "dotbot"),
        (Join-Path $ProjectDir ".claude\commands\dotbot"),
        (Join-Path $ProjectDir ".claude\agents\dotbot")
    )
    
    foreach ($path in $pathsToRemove) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            Write-Verbose "Removed: $path"
        }
    }
}

# Install components
Install-Standards
Install-Workflows
Install-Commands
Install-Agents

# Show summary
if (-not $DryRun) {
    Show-InstallationSummary
}
