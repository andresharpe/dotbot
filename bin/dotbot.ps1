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
$DotbotBase = Join-Path $HOME "dotbot"
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
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T" -ForegroundColor Blue
    Write-Host "    Spec-Driven Agentic Development" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  GLOBAL COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    install           " -NoNewline -ForegroundColor Yellow
    Write-Host "Install dotbot globally" -ForegroundColor White
    Write-Host "    update            " -NoNewline -ForegroundColor Yellow
    Write-Host "Update global installation" -ForegroundColor White
    Write-Host "    uninstall         " -NoNewline -ForegroundColor Yellow
    Write-Host "Remove global installation" -ForegroundColor White
    Write-Host ""
    Write-Host "  PROJECT COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    init              " -NoNewline -ForegroundColor Yellow
    Write-Host "Initialize dotbot in current project" -ForegroundColor White
    Write-Host "    update-project    " -NoNewline -ForegroundColor Yellow
    Write-Host "Update project to latest version" -ForegroundColor White
    Write-Host "    remove-project    " -NoNewline -ForegroundColor Yellow
    Write-Host "Remove dotbot from current project" -ForegroundColor White
    Write-Host ""
    Write-Host "  INFO COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    status            " -NoNewline -ForegroundColor Yellow
    Write-Host "Show global and project status" -ForegroundColor White
    Write-Host "    help              " -NoNewline -ForegroundColor Yellow
    Write-Host "Show this help message" -ForegroundColor White
    Write-Host ""
    Write-Host "  INIT OPTIONS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    --profile <name>         " -NoNewline -ForegroundColor Cyan
    Write-Host "Use specific profile" -ForegroundColor White
    Write-Host "    --warp-commands          " -NoNewline -ForegroundColor Cyan
    Write-Host "Install Warp slash commands (default)" -ForegroundColor White
    Write-Host "    --no-warp-commands       " -NoNewline -ForegroundColor Cyan
    Write-Host "Skip Warp commands" -ForegroundColor White
    Write-Host "    --warp-rules             " -NoNewline -ForegroundColor Cyan
    Write-Host "Add standards to WARP.md" -ForegroundColor White
    Write-Host "    --commands               " -NoNewline -ForegroundColor Cyan
    Write-Host "Install standalone .bot/commands/" -ForegroundColor White
    Write-Host "    --force, -f              " -NoNewline -ForegroundColor Cyan
    Write-Host "Overwrite existing installation" -ForegroundColor White
    Write-Host "    --interactive, -i        " -NoNewline -ForegroundColor Cyan
    Write-Host "Interactive setup" -ForegroundColor White
    Write-Host "    --dry-run, -n            " -NoNewline -ForegroundColor Cyan
    Write-Host "Preview without changes" -ForegroundColor White
    Write-Host "    --verbose, -v            " -NoNewline -ForegroundColor Cyan
    Write-Host "Detailed output" -ForegroundColor White
    Write-Host ""
    Write-Host "  EXAMPLES" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    # Global operations" -ForegroundColor DarkGray
    Write-Host "    dotbot install" -ForegroundColor Yellow
    Write-Host "    dotbot update" -ForegroundColor Yellow
    Write-Host "    dotbot uninstall" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    # Project operations" -ForegroundColor DarkGray
    Write-Host "    dotbot init" -ForegroundColor Yellow
    Write-Host "    dotbot init --profile rails" -ForegroundColor Yellow
    Write-Host "    dotbot init --no-warp-commands --commands" -ForegroundColor Yellow
    Write-Host "    dotbot update-project" -ForegroundColor Yellow
    Write-Host "    dotbot remove-project" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    # Status" -ForegroundColor DarkGray
    Write-Host "    dotbot status" -ForegroundColor Yellow
    Write-Host ""
}

function Test-DotbotInstalled {
    return (Test-Path $DotbotBase) -and (Test-Path (Join-Path $DotbotBase "config.yml"))
}

function Invoke-Install {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T" -ForegroundColor Blue
    Write-Host "    Base Installation" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    if (Test-DotbotInstalled) {
        Write-DotbotError "dotbot is already installed at: $DotbotBase" `
            "Use 'dotbot update' to update or 'dotbot uninstall' to remove"
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
            '^-+(profile)$' {
                if ($i + 1 -lt $Arguments.Count) {
                    $params['Profile'] = $Arguments[$i + 1]
                    $i++
                }
            }
            '^-+(warp-commands)$' {
                $params['WarpCommands'] = $true
            }
            '^-+(no-warp-commands)$' {
                $params['WarpCommands'] = $false
            }
            '^-+(warp-rules)$' {
                $params['StandardsAsWarpRules'] = $true
            }
            '^-+(commands)$' {
                $params['DotbotCommands'] = $true
            }
            '^-+(force|f)$' {
                $params['Force'] = $true
            }
            '^-+(interactive|i)$' {
                $params['Interactive'] = $true
            }
            '^-+(dry-run|n)$' {
                $params['DryRun'] = $true
            }
            '^-+(verbose|v)$' {
                $params['Verbose'] = $true
            }
        }
    }
    
    # Call project-install script
    $projectInstallScript = Join-Path $ScriptsDir "project-install.ps1"
    & ${projectInstallScript} @params
}


function Invoke-Status {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T" -ForegroundColor Blue
    Write-Host "    Status" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    # Check global installation
    if (Test-DotbotInstalled) {
        Write-Host "  GLOBAL INSTALLATION" -ForegroundColor Blue
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✓ Installed" -ForegroundColor Blue
        Write-Host "    Location: " -NoNewline -ForegroundColor Yellow
        Write-Host "$DotbotBase" -ForegroundColor White
        
        # Get version
        $configPath = Join-Path $DotbotBase "config.yml"
        if (Test-Path $configPath) {
            $version = Get-ConfigValue -ConfigPath $configPath -Key "version"
            Write-Host "    Version:  " -NoNewline -ForegroundColor Yellow
            Write-Host "$version" -ForegroundColor White
        }
        Write-Host ""
    } else {
        Write-Host "  GLOBAL INSTALLATION" -ForegroundColor Blue
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✗ Not installed" -ForegroundColor Red
        Write-Host ""
        Write-DotbotError "dotbot is not installed" `
            "Run 'dotbot install' to set up dotbot globally"
        return
    }
    
    # Check project installation
    $botDir = Join-Path (Get-Location) ".bot"
    Write-Host "  PROJECT INSTALLATION" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    
    if (Test-Path $botDir) {
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✓ Enabled" -ForegroundColor Blue
        Write-Host "    Location: " -NoNewline -ForegroundColor Yellow
        Write-Host "$botDir" -ForegroundColor White
        
        # Check for state file (future enhancement)
        $stateFile = Join-Path $botDir ".dotbot-state.json"
        if (Test-Path $stateFile) {
            Write-Host "    State:    " -NoNewline -ForegroundColor Yellow
            Write-Host "Tracked" -ForegroundColor White
        }
        
        # Check what's installed
        $standardsDir = Join-Path $botDir "standards"
        $workflowsDir = Join-Path $botDir "workflows"
        $commandsDir = Join-Path $botDir "commands"
        $warpCommandsDir = Join-Path (Get-Location) ".warp\commands\dotbot"
        
        if (Test-Path $standardsDir) {
            $standardsCount = (Get-ChildItem -Path $standardsDir -Recurse -File).Count
            Write-Host "    Standards: " -NoNewline -ForegroundColor Yellow
            Write-Host "$standardsCount files" -ForegroundColor White
        }
        
        if (Test-Path $workflowsDir) {
            $workflowsCount = (Get-ChildItem -Path $workflowsDir -Recurse -File).Count
            Write-Host "    Workflows: " -NoNewline -ForegroundColor Yellow
            Write-Host "$workflowsCount files" -ForegroundColor White
        }
        
        if (Test-Path $warpCommandsDir) {
            $commandsCount = (Get-ChildItem -Path $warpCommandsDir -File).Count
            Write-Host "    Commands:  " -NoNewline -ForegroundColor Yellow
            Write-Host "$commandsCount Warp commands" -ForegroundColor White
        } elseif (Test-Path $commandsDir) {
            $commandsCount = (Get-ChildItem -Path $commandsDir -File).Count
            Write-Host "    Commands:  " -NoNewline -ForegroundColor Yellow
            Write-Host "$commandsCount installed" -ForegroundColor White
        }
        
        Write-Host ""
    } else {
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✗ Not initialized" -ForegroundColor Red
        Write-Host ""
        Write-Host "    • " -NoNewline -ForegroundColor Yellow
        Write-Host "Run 'dotbot init' to add dotbot to this project" -ForegroundColor White
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
    "status" {
        Invoke-Status
    }
    "update" {
        $updateScript = Join-Path $ScriptsDir "update.ps1"
        if (Test-Path $updateScript) {
            if ($Arguments -and $Arguments.Count -gt 0) {
                & ${updateScript} $Arguments
            } else {
                & ${updateScript}
            }
        } else {
            Write-DotbotError "Update script not found" `
                "Reinstall dotbot or check $updateScript"
        }
    }
    "update-project" {
        $upgradeScript = Join-Path $ScriptsDir "upgrade-project.ps1"
        Write-Host "DEBUG: upgradeScript = $upgradeScript" -ForegroundColor Cyan
        Write-Host "DEBUG: Type = $($upgradeScript.GetType().Name)" -ForegroundColor Cyan
        Write-Host "Press any key to continue..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if (Test-Path $upgradeScript) {
            if ($Arguments -and $Arguments.Count -gt 0) {
                & ${upgradeScript} $Arguments
            } else {
                & ${upgradeScript}
            }
        } else {
            Write-DotbotError "Upgrade script not found" `
                "Reinstall dotbot or check $upgradeScript"
        }
    }
    "remove-project" {
        $uninstallScript = Join-Path $ScriptsDir "uninstall.ps1"
        if (Test-Path $uninstallScript) {
            $params = @{ Project = $true }
            & ${uninstallScript} @params
        } else {
            Write-DotbotError "Uninstall script not found" `
                "Reinstall dotbot or check $uninstallScript"
        }
    }
    "uninstall" {
        $uninstallScript = Join-Path $ScriptsDir "uninstall.ps1"
        if (Test-Path $uninstallScript) {
            $params = @{ Global = $true }
            & ${uninstallScript} @params
        } else {
            Write-DotbotError "Uninstall script not found" `
                "Reinstall dotbot or check $uninstallScript"
        }
    }
    default {
        Write-DotbotError "Unknown command: $Command" `
            "Run 'dotbot help' to see available commands"
        exit 1
    }
}
