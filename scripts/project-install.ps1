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
# Git Initialization
# -----------------------------------------------------------------------------

function Initialize-GitIfNeeded {
    $gitDir = Join-Path $ProjectDir ".git"
    
    if (Test-Path $gitDir) {
        Write-Host "  ✓ Git repository detected" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  ℹ Git repository not found" -ForegroundColor Yellow
        Write-Host "  ℹ Warp workflows require a git repository" -ForegroundColor Yellow
        Write-Host ""
        
        if (-not $DryRun) {
            try {
                git init | Out-Null
                Write-Host "  ✓ Git repository initialized" -ForegroundColor Green
                Write-Host ""
                return $true
            } catch {
                Write-Warning "Failed to initialize git repository: $_"
                Write-Warning "Warp workflows will not be available without git"
                Write-Host ""
                return $false
            }
        } else {
            Write-Host "  [DRY RUN] Would initialize git repository" -ForegroundColor Cyan
            Write-Host ""
            return $false
        }
    }
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

function Install-Agents {
    if (-not $DryRun) {
        Write-Status "Installing agents"
    }
    
    $agentsCount = 0
    $overwrite = $OverwriteAll
    
    $files = Get-ProfileFiles -Profile $script:EffectiveProfile -BaseDir $BaseDir -Subfolder "agents"
    
    foreach ($file in $files) {
        $source = Get-ProfileFile -Profile $script:EffectiveProfile -RelativePath $file -BaseDir $BaseDir
        $dest = Join-Path $ProjectDir ".bot\$file"
        
        if ($source) {
            $installedFile = Copy-DotbotFile -Source $source -Destination $dest -Overwrite $overwrite -DryRun:$DryRun
            if ($installedFile) {
                $script:InstalledFiles += $installedFile
                $agentsCount++
            }
        }
    }
    
    if (-not $DryRun -and $agentsCount -gt 0) {
        Write-Success "Installed $agentsCount agents in .bot\agents"
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

function Install-WarpWorkflowShims {
    if (-not $script:GitInitialized) {
        Write-VerboseLog "Skipping Warp workflow shims (git not initialized)"
        return
    }
    
    $workflowsDir = Join-Path $ProjectDir ".bot\workflows"
    if (-not (Test-Path $workflowsDir)) {
        Write-VerboseLog "No workflows directory found, skipping Warp workflow shims"
        return
    }
    
    if (-not $DryRun) {
        Write-Status "Creating Warp workflow shims"
    }
    
    $warpWorkflowsDir = Join-Path $ProjectDir ".warp\workflows"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $warpWorkflowsDir | Out-Null
    }
    
    $shimCount = 0
    $workflowFiles = Get-ChildItem -Path $workflowsDir -Recurse -Filter "*.md" -File
    
    foreach ($workflowFile in $workflowFiles) {
        # Get relative path from .bot/workflows/
        $relativePath = $workflowFile.FullName.Substring($workflowsDir.Length + 1)
        
        # Convert to forward slashes for the command (works on Windows too)
        $commandPath = $relativePath -replace "\\", "/"
        
        # Get the base name without extension
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($workflowFile.Name)
        
        # Determine the category and order number from the parent folder and workflow name
        $parentFolder = Split-Path -Parent $relativePath
        $orderPrefix = ""
        
        if ($parentFolder -match "planning") {
            $category = "planning"
            $orderPrefix = "1"
        } elseif ($parentFolder -match "specification") {
            $category = "specification"
            # Sub-ordering for specification workflows
            if ($baseName -match "research") {
                $orderPrefix = "2"
            } elseif ($baseName -match "write") {
                $orderPrefix = "3"
            } else {
                $orderPrefix = "2"
            }
        } elseif ($baseName -match "create-tasks") {
            $category = "tasks"
            $orderPrefix = "4"
        } elseif ($parentFolder -match "implementation") {
            $category = "implementation"
            $orderPrefix = "5"
        } elseif ($parentFolder -match "verification") {
            $category = "verification"
            $orderPrefix = "6"
        } else {
            $category = "workflows"
            $orderPrefix = "9"
        }
        
        # Create the YAML content
        $yamlContent = @"
name: dotbot-$orderPrefix-$baseName
command: Execute the instructions at .bot\workflows\$commandPath
description: Execute the instructions at .bot\workflows\$commandPath
tags: ["bot", "workflows", "$category"]
"@
        
        # Write the YAML file
        $yamlPath = Join-Path $warpWorkflowsDir "$baseName.yaml"
        
        if (-not $DryRun) {
            Set-Content -Path $yamlPath -Value $yamlContent -Encoding UTF8
            $script:InstalledFiles += $yamlPath
            $shimCount++
        } else {
            Write-Host "  [DRY RUN] Would create: $yamlPath" -ForegroundColor Cyan
            $shimCount++
        }
    }
    
    if (-not $DryRun -and $shimCount -gt 0) {
        Write-Success "Created $shimCount Warp workflow shims in .warp\workflows"
    } elseif ($DryRun -and $shimCount -gt 0) {
        Write-Host "  [DRY RUN] Would create $shimCount Warp workflow shims" -ForegroundColor Cyan
    }
}


function Show-WorkflowMap {
    Write-Host ""
    Write-Host "  WORKFLOW" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  📋 Plan → 🔍 Shape → 📝 Specify → ✂️ Tasks → ⚡ Implement → ✅ Verify" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  WORKFLOWS (Press Ctrl-Shift-R in Warp)" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    dotbot-1-gather-product-info    " -NoNewline -ForegroundColor Yellow
    Write-Host "📋 Define product vision & roadmap" -ForegroundColor White
    Write-Host "    dotbot-2-research-spec          " -NoNewline -ForegroundColor Yellow
    Write-Host "🔍 Research and scope features" -ForegroundColor White
    Write-Host "    dotbot-3-write-spec             " -NoNewline -ForegroundColor Yellow
    Write-Host "📝 Write technical specifications" -ForegroundColor White
    Write-Host "    dotbot-4-create-tasks-list      " -NoNewline -ForegroundColor Yellow
    Write-Host "✂️ Break specs into tasks" -ForegroundColor White
    Write-Host "    dotbot-5-implement-tasks        " -NoNewline -ForegroundColor Yellow
    Write-Host "⚡ Execute with verification" -ForegroundColor White
    Write-Host "    dotbot-6-verify-implementation  " -NoNewline -ForegroundColor Yellow
    Write-Host "✅ Validate requirements met" -ForegroundColor White
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
    Write-Host "Press Ctrl-Shift-R → dotbot-1-gather-product-info to start" -ForegroundColor White
    Write-Host "    • " -NoNewline -ForegroundColor Yellow
    Write-Host "Follow the workflow: Plan → Shape → Specify → Tasks → Implement → Verify" -ForegroundColor White
    Write-Host "    • " -NoNewline -ForegroundColor Yellow
    Write-Host "Review standards in .bot\standards" -ForegroundColor White
    if ($script:GitInitialized) {
        Write-Host "    • " -NoNewline -ForegroundColor Yellow
        Write-Host "All workflows available via Ctrl-Shift-R (dotbot-*)" -ForegroundColor White
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

# Check and initialize git if needed
Write-Status "Checking git repository"
$script:GitInitialized = Initialize-GitIfNeeded

# Handle re-install
if ($ReInstall -and -not $DryRun) {
    Write-Warning "Re-installing dotbot (removing existing files)..."
    
    $pathsToRemove = @(
        (Join-Path $ProjectDir ".bot"),
        (Join-Path $ProjectDir ".warp\commands\dotbot"),
        (Join-Path $ProjectDir ".warp\workflows")
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
Install-Agents
Install-Workflows
Install-Commands
Install-WarpWorkflowShims

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

