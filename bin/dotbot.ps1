# =============================================================================
# dotbot CLI
# Main command-line interface for dotbot
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

# Paths
$DotbotBase = Join-Path $env:USERPROFILE "dotbot"
$ScriptsDir = Join-Path $DotbotBase "scripts"

# Import common functions if available
$commonFunctionsPath = Join-Path $ScriptsDir "Common-Functions.psm1"
if (Test-Path $commonFunctionsPath) {
    Import-Module $commonFunctionsPath -Force
}

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Write-DotbotError {
    param([string]$Message, [string]$Suggestion = "")
    Write-Host ""
    Write-Host "❌ $Message" -ForegroundColor Red
    if ($Suggestion) {
        Write-Host "💡 $Suggestion" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-Help {
    Write-Host ""
    Write-Host "dotbot - Your system for spec-driven agentic development" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  dotbot <command> [options]"
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  install              Install dotbot globally (base installation)"
    Write-Host "  init                 Initialize dotbot in current project"
    Write-Host "  setup                Smart setup for existing projects"
    Write-Host "  status               Show dotbot installation status"
    Write-Host "  help                 Show this help message"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  dotbot install       # First-time setup on new PC"
    Write-Host "  dotbot init          # Add dotbot to your project"
    Write-Host "  dotbot status        # Check what's installed"
    Write-Host ""
    Write-Host "For more information: https://github.com/yourusername/dotbot" -ForegroundColor Gray
    Write-Host ""
}

function Test-DotbotInstalled {
    return (Test-Path $DotbotBase) -and (Test-Path (Join-Path $DotbotBase "config.yml"))
}

function Invoke-Install {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "   dotbot Base Installation" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    
    if (Test-DotbotInstalled) {
        Write-DotbotError "dotbot is already installed at: $DotbotBase" `
            "Use 'dotbot update' to update or 'dotbot uninstall --global' to remove"
        return
    }
    
    Write-DotbotError "Interactive installation not yet implemented" `
        "Please run: cd ~\dotbot && .\scripts\base-install.ps1"
}

function Invoke-Init {
    if (-not (Test-DotbotInstalled)) {
        Write-DotbotError "dotbot is not installed on this PC" `
            "Run 'dotbot install' first"
        return
    }
    
    # Parse arguments
    $params = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        switch -Regex ($arg) {
            '^-+Profile$' {
                if ($i + 1 -lt $Arguments.Count) {
                    $params['Profile'] = $Arguments[$i + 1]
                    $i++
                }
            }
            '^-+WarpCommands$' {
                if ($i + 1 -lt $Arguments.Count) {
                    $params['WarpCommands'] = [bool]::Parse($Arguments[$i + 1])
                    $i++
                }
            }
            '^-+DotbotCommands$' {
                if ($i + 1 -lt $Arguments.Count) {
                    $params['DotbotCommands'] = [bool]::Parse($Arguments[$i + 1])
                    $i++
                }
            }
            '^-+StandardsAsWarpRules$' {
                if ($i + 1 -lt $Arguments.Count) {
                    $params['StandardsAsWarpRules'] = [bool]::Parse($Arguments[$i + 1])
                    $i++
                }
            }
            '^-+(Interactive|i)$' {
                $params['Interactive'] = $true
            }
            '^-+(DryRun|n)$' {
                $params['DryRun'] = $true
            }
            '^-+(Verbose|v)$' {
                $params['Verbose'] = $true
            }
        }
    }
    
    # Call project-install script
    $projectInstallScript = Join-Path $ScriptsDir "project-install.ps1"
    & $projectInstallScript @params
}

function Invoke-Setup {
    if (-not (Test-DotbotInstalled)) {
        Write-Host ""
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host "   dotbot Smart Setup" -ForegroundColor Cyan
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host ""
        Write-DotbotError "dotbot is not installed on this PC" `
            "Run 'dotbot install' first to set up dotbot globally"
        return
    }
    
    # Check if current directory has .bot/
    $botDir = Join-Path (Get-Location) ".bot"
    
    if (Test-Path $botDir) {
        Write-Host ""
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host "   dotbot Smart Setup" -ForegroundColor Cyan
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "✓ Detected existing dotbot project" -ForegroundColor Green
        Write-Host ""
        Write-Host "This project already has dotbot installed (.bot/ folder exists)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "What would you like to do?" -ForegroundColor Yellow
        Write-Host "  1. Check status (dotbot status)"
        Write-Host "  2. Re-install/update (dotbot init --reinstall)"
        Write-Host "  3. Nothing, I'm good"
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host "   dotbot Smart Setup" -ForegroundColor Cyan
        Write-Host "====================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "No dotbot configuration found in this project" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "💡 Run 'dotbot init' to add dotbot to this project" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Invoke-Status {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "   dotbot Status" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Check global installation
    if (Test-DotbotInstalled) {
        Write-Host "Global Installation:" -ForegroundColor Yellow
        Write-Host "  Status:   " -NoNewline
        Write-Host "✓ Installed" -ForegroundColor Green
        Write-Host "  Location: $DotbotBase"
        
        # Get version
        $configPath = Join-Path $DotbotBase "config.yml"
        if (Test-Path $configPath) {
            $version = Get-ConfigValue -ConfigPath $configPath -Key "version"
            Write-Host "  Version:  $version"
        }
        Write-Host ""
    } else {
        Write-Host "Global Installation:" -ForegroundColor Yellow
        Write-Host "  Status:   " -NoNewline
        Write-Host "✗ Not installed" -ForegroundColor Red
        Write-Host ""
        Write-DotbotError "dotbot is not installed" `
            "Run 'dotbot install' to set up dotbot globally"
        return
    }
    
    # Check project installation
    $botDir = Join-Path (Get-Location) ".bot"
    Write-Host "Project Installation:" -ForegroundColor Yellow
    
    if (Test-Path $botDir) {
        Write-Host "  Status:   " -NoNewline
        Write-Host "✓ Enabled" -ForegroundColor Green
        Write-Host "  Location: $botDir"
        
        # Check for state file (future enhancement)
        $stateFile = Join-Path $botDir ".dotbot-state.json"
        if (Test-Path $stateFile) {
            Write-Host "  State:    Tracked"
        }
        
        # Check what's installed
        $standardsDir = Join-Path $botDir "standards"
        $workflowsDir = Join-Path $botDir "workflows"
        $commandsDir = Join-Path $botDir "commands"
        $warpCommandsDir = Join-Path (Get-Location) ".warp\commands\dotbot"
        
        if (Test-Path $standardsDir) {
            $standardsCount = (Get-ChildItem -Path $standardsDir -Recurse -File).Count
            Write-Host "  Standards: $standardsCount files"
        }
        
        if (Test-Path $workflowsDir) {
            $workflowsCount = (Get-ChildItem -Path $workflowsDir -Recurse -File).Count
            Write-Host "  Workflows: $workflowsCount files"
        }
        
        if (Test-Path $warpCommandsDir) {
            $commandsCount = (Get-ChildItem -Path $warpCommandsDir -File).Count
            Write-Host "  Warp Commands: $commandsCount installed"
        } elseif (Test-Path $commandsDir) {
            $commandsCount = (Get-ChildItem -Path $commandsDir -File).Count
            Write-Host "  Commands: $commandsCount installed"
        }
        
        Write-Host ""
    } else {
        Write-Host "  Status:   " -NoNewline
        Write-Host "✗ Not initialized" -ForegroundColor Red
        Write-Host ""
        Write-Host "💡 Run 'dotbot init' to add dotbot to this project" -ForegroundColor Yellow
        Write-Host ""
    }
}

# -----------------------------------------------------------------------------
# Main Command Router
# -----------------------------------------------------------------------------

if (-not $Command -or $Command -eq "help" -or $Command -eq "-h" -or $Command -eq "--help") {
    Show-Help
    exit 0
}

switch ($Command.ToLower()) {
    "install" {
        Invoke-Install
    }
    "init" {
        Invoke-Init
    }
    "setup" {
        Invoke-Setup
    }
    "status" {
        Invoke-Status
    }
    default {
        Write-DotbotError "Unknown command: $Command" `
            "Run 'dotbot help' to see available commands"
        exit 1
    }
}
