#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install dotbot globally to ~/dotbot

.DESCRIPTION
    Copies dotbot files to ~/dotbot and adds the CLI to PATH
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$SourceDir
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
if (-not $SourceDir) {
    $SourceDir = Split-Path -Parent $ScriptDir
}
$BaseDir = Join-Path $HOME "dotbot"
$BinDir = Join-Path $BaseDir "bin"

# Import platform functions
Import-Module (Join-Path $ScriptDir "Platform-Functions.psm1") -Force

Write-Status "Installing dotbot to $BaseDir"

# Check if source and destination are the same
$resolvedSource = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
$resolvedBase = if (Test-Path $BaseDir) { (Resolve-Path $BaseDir).Path.TrimEnd('\', '/') } else { $null }

if ($resolvedBase -and ($resolvedSource -eq $resolvedBase)) {
    Write-Success "Already running from target installation directory"
    Write-Success "dotbot is installed at: $BaseDir"
} else {
    if ($DryRun) {
        Write-Host "  Would copy files from: $SourceDir" -ForegroundColor Yellow
        Write-Host "  Would copy to: $BaseDir" -ForegroundColor Yellow
    } else {
        # Create base directory
        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        }
        
        # Copy all files except .git
        $itemsToCopy = Get-ChildItem -Path $SourceDir -Exclude ".git", ".vs"
        
        foreach ($item in $itemsToCopy) {
            $dest = Join-Path $BaseDir $item.Name
            
            if ($item.PSIsContainer) {
                if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
                Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
            } else {
                Copy-Item -Path $item.FullName -Destination $dest -Force
            }
        }
        
        Write-Success "Files copied to: $BaseDir"
    }
}

# Create bin directory with dotbot CLI wrapper
if (-not $DryRun) {
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    }
    
    # Create dotbot.ps1 CLI wrapper
    $cliScript = Join-Path $BinDir "dotbot.ps1"
$cliContent = @'
#!/usr/bin/env pwsh
# dotbot CLI wrapper
# Reset strict mode — callers (e.g. setup scripts) may set
# Set-StrictMode -Version Latest which breaks intrinsic .Count
Set-StrictMode -Off
$DotbotBase = Join-Path $HOME "dotbot"
$ScriptsDir = Join-Path $DotbotBase "scripts"

# Import common functions
Import-Module (Join-Path $ScriptsDir "Platform-Functions.psm1") -Force

$Command = $args[0]
[array]$SubArgs = if ($args.Count -gt 1) { $args[1..($args.Count-1)] } else { @() }

# Convert CLI args to a hashtable for proper named-parameter splatting.
# Array splatting only does positional binding; hashtable splatting is
# required for named parameters like -Workflow / -Stack.
$SplatArgs = @{}
if ($args.Count -gt 1) {
    $raw = $args[1..($args.Count-1)]
    $i = 0
    while ($i -lt $raw.Count) {
        if ($raw[$i] -match '^--?(.+)$') {
            $name = $Matches[1]
            if (($i + 1) -lt $raw.Count -and $raw[$i + 1] -notmatch '^--?') {
                $SplatArgs[$name] = $raw[$i + 1]
                $i += 2
            } else {
                $SplatArgs[$name] = $true
                $i++
            }
        } else {
            $i++
        }
    }
}

# Read canonical version from version.json
$DotbotVersion = 'unknown'
try {
    $vf = Join-Path $DotbotBase 'version.json'
    if (Test-Path $vf) { $DotbotVersion = (Get-Content $vf -Raw | ConvertFrom-Json).version }
} catch { Write-Verbose "Failed to parse data: $_" }
$env:DOTBOT_VERSION = $DotbotVersion

function Show-Help {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v$DotbotVersion" -ForegroundColor Blue
    Write-Host "    Autonomous Development System" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    init              " -NoNewline -ForegroundColor Yellow
    Write-Host "Initialize .bot in current project" -ForegroundColor White
    Write-Host "    workflow add      " -NoNewline -ForegroundColor Yellow
    Write-Host "Add a workflow to existing project" -ForegroundColor White
    Write-Host "    workflow remove   " -NoNewline -ForegroundColor Yellow
    Write-Host "Remove an installed workflow" -ForegroundColor White
    Write-Host "    workflow list     " -NoNewline -ForegroundColor Yellow
    Write-Host "List installed workflows" -ForegroundColor White
    Write-Host "    run               " -NoNewline -ForegroundColor Yellow
    Write-Host "Run/rerun a workflow" -ForegroundColor White
    Write-Host "    resume            " -NoNewline -ForegroundColor Yellow
    Write-Host "Resume a paused workflow" -ForegroundColor White
    Write-Host "    list              " -NoNewline -ForegroundColor Yellow
    Write-Host "List available workflows and stacks" -ForegroundColor White
    Write-Host "    status            " -NoNewline -ForegroundColor Yellow
    Write-Host "Show installation status" -ForegroundColor White
    Write-Host "    registry add      " -NoNewline -ForegroundColor Yellow
    Write-Host "Add an enterprise extension registry" -ForegroundColor White
    Write-Host "    registry list     " -NoNewline -ForegroundColor Yellow
    Write-Host "List registered extension registries" -ForegroundColor White
    Write-Host "    registry remove   " -NoNewline -ForegroundColor Yellow
    Write-Host "Remove an extension registry" -ForegroundColor White
    Write-Host "    update            " -NoNewline -ForegroundColor Yellow
    Write-Host "Update global installation" -ForegroundColor White
    Write-Host "    doctor            " -NoNewline -ForegroundColor Yellow
    Write-Host "Scan project for health issues" -ForegroundColor White
    Write-Host "    help              " -NoNewline -ForegroundColor Yellow
    Write-Host "Show this help message" -ForegroundColor White
    Write-Host ""
}

function Invoke-Init {
    $initScript = Join-Path $ScriptsDir "init-project.ps1"
    if (Test-Path $initScript) {
        if ($SplatArgs.Count -gt 0) {
            & $initScript @SplatArgs
        } else {
            & $initScript
        }
    } else {
        Write-Host "  ✗ Init script not found" -ForegroundColor Red
    }
}

function Invoke-Status {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v$DotbotVersion" -ForegroundColor Blue
    Write-Host "    Status" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    # Check global installation
    Write-Host "  GLOBAL INSTALLATION" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
    Write-Host "✓ Installed" -ForegroundColor Green
    Write-Host "    Location: " -NoNewline -ForegroundColor Yellow
    Write-Host "$DotbotBase" -ForegroundColor White
    Write-Host ""
    
    # Check project installation
    $botDir = Join-Path (Get-Location) ".bot"
    Write-Host "  PROJECT INSTALLATION" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    
    if (Test-Path $botDir) {
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✓ Enabled" -ForegroundColor Green
        Write-Host "    Location: " -NoNewline -ForegroundColor Yellow
        Write-Host "$botDir" -ForegroundColor White
        
        # Count components
        $mcpDir = Join-Path $botDir "systems\mcp"
        $uiDir = Join-Path $botDir "systems\ui"
        $promptsDir = Join-Path $botDir "prompts"
        
        if (Test-Path $mcpDir) {
            Write-Host "    MCP:      " -NoNewline -ForegroundColor Yellow
            Write-Host "✓ Available" -ForegroundColor Green
        }
        if (Test-Path $uiDir) {
            Write-Host "    UI:       " -NoNewline -ForegroundColor Yellow
            Write-Host "✓ Available (default port 8686)" -ForegroundColor Green
        }
        if (Test-Path $promptsDir) {
            $agentCount = (Get-ChildItem -Path (Join-Path $promptsDir "agents") -Directory -ErrorAction SilentlyContinue).Count
            $skillCount = (Get-ChildItem -Path (Join-Path $promptsDir "skills") -Directory -ErrorAction SilentlyContinue).Count
            Write-Host "    Agents:   " -NoNewline -ForegroundColor Yellow
            Write-Host "$agentCount" -ForegroundColor White
            Write-Host "    Skills:   " -NoNewline -ForegroundColor Yellow
            Write-Host "$skillCount" -ForegroundColor White
        }
        Write-Host ""
    } else {
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✗ Not initialized" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Run 'dotbot init' to add dotbot to this project" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Invoke-List {
    $workflowsDir = Join-Path $DotbotBase "workflows"
    $stacksDir = Join-Path $DotbotBase "stacks"

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v$DotbotVersion" -ForegroundColor Blue
    Write-Host "    Available Workflows & Stacks" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""

    # Workflows
    if (Test-Path $workflowsDir) {
        $wfDirs = @(Get-ChildItem -Path $workflowsDir -Directory)
        if ($wfDirs.Count -gt 0) {
            Write-Host "  WORKFLOWS" -ForegroundColor Blue
            Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host ""
            foreach ($d in $wfDirs) {
                $yamlPath = Join-Path $d.FullName "manifest.yaml"
                if (-not (Test-Path $yamlPath)) { $yamlPath = Join-Path $d.FullName "workflow.yaml" }
                $desc = ""
                if (Test-Path $yamlPath) {
                    Get-Content $yamlPath | ForEach-Object {
                        if ($_ -match '^\s*description:\s*(.+)$') { $desc = $Matches[1].Trim() }
                    }
                }
                Write-Host "    $($d.Name.PadRight(24))" -NoNewline -ForegroundColor Yellow
                Write-Host $desc -ForegroundColor White
            }
            Write-Host ""
        }
    }

    # Stacks
    if (Test-Path $stacksDir) {
        $stDirs = @(Get-ChildItem -Path $stacksDir -Directory)
        if ($stDirs.Count -gt 0) {
            Write-Host "  STACKS (composable)" -ForegroundColor Blue
            Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host ""
            foreach ($d in $stDirs) {
                $yamlPath = Join-Path $d.FullName "manifest.yaml"
                $desc = ""; $extends = ""
                if (Test-Path $yamlPath) {
                    Get-Content $yamlPath | ForEach-Object {
                        if ($_ -match '^\s*description:\s*(.+)$') { $desc = $Matches[1].Trim() }
                        if ($_ -match '^\s*extends:\s*(.+)$') { $extends = $Matches[1].Trim() }
                    }
                }
                $label = $d.Name
                if ($extends) { $label += " (extends: $extends)" }
                Write-Host "    $($label.PadRight(36))" -NoNewline -ForegroundColor Yellow
                Write-Host $desc -ForegroundColor White
            }
            Write-Host ""
        }
    }

    Write-Host "  USAGE" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    dotbot init --stack dotnet" -ForegroundColor White
    Write-Host "    dotbot init --workflow kickstart-via-jira --stack dotnet-blazor" -ForegroundColor White
    Write-Host ""
}

function Invoke-Update {
    Write-Host ""
    Write-Host "  To update dotbot:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    cd ~/dotbot" -ForegroundColor White
    Write-Host "    git pull" -ForegroundColor White
    Write-Host "    ./install.ps1" -ForegroundColor White
    Write-Host ""
}

function Invoke-Workflow {
    $wfSubCmd = if ($SubArgs.Count -gt 0) { $SubArgs[0] } else { 'list' }
    $wfName = if ($SubArgs.Count -gt 1) { $SubArgs[1] } else { '' }
    $wfExtra = if ($SubArgs.Count -gt 2) { @($SubArgs[2..($SubArgs.Count-1)]) } else { @() }
    $wfScript = switch ($wfSubCmd) {
        'add'    { Join-Path $ScriptsDir 'workflow-add.ps1' }
        'remove' { Join-Path $ScriptsDir 'workflow-remove.ps1' }
        'list'   { Join-Path $ScriptsDir 'workflow-list.ps1' }
        default  { $null }
    }
    if ($wfScript -and (Test-Path $wfScript)) {
        & $wfScript $wfName @wfExtra
    } else {
        Write-Host "  Usage: dotbot workflow [add|remove|list] [name] [--Force]" -ForegroundColor Yellow
    }
}

function Invoke-Registry {
    # Parse: registry add <name> <source> [--branch <branch>] [--force]
    $regSubCmd = if ($SubArgs.Count -gt 0) { $SubArgs[0] } else { '' }
    $regRest = if ($SubArgs.Count -gt 1) { @($SubArgs[1..($SubArgs.Count-1)]) } else { @() }

    $regScript = switch ($regSubCmd) {
        'add'    { Join-Path $ScriptsDir 'registry-add.ps1' }
        'remove' { Join-Path $ScriptsDir 'registry-remove.ps1' }
        'list'   { Join-Path $ScriptsDir 'registry-list.ps1' }
        default  { $null }
    }

    if ($regScript -and (Test-Path $regScript)) {
        # Separate positional args from named flags
        $regSplat = @{}
        $positional = @()
        $ri = 0
        while ($ri -lt $regRest.Count) {
            if ($regRest[$ri] -match '^--?(.+)$') {
                $pname = $Matches[1]
                if (($ri + 1) -lt $regRest.Count -and $regRest[$ri + 1] -notmatch '^--?') {
                    $regSplat[$pname] = $regRest[$ri + 1]
                    $ri += 2
                } else {
                    $regSplat[$pname] = $true
                    $ri++
                }
            } else {
                $positional += $regRest[$ri]
                $ri++
            }
        }

        # Map positional args to named parameters
        if ($regSubCmd -eq 'add') {
            if ($positional.Count -ge 1) { $regSplat['Name'] = $positional[0] }
            if ($positional.Count -ge 2) { $regSplat['Source'] = $positional[1] }
        } elseif ($regSubCmd -eq 'remove') {
            if ($positional.Count -ge 1) { $regSplat['Name'] = $positional[0] }
        }

        & $regScript @regSplat
    } else {
        Write-Host "  Usage: dotbot registry [add] <name> <source> [--branch main] [--force]" -ForegroundColor Yellow
    }
}

function Invoke-Run {
    $wfName = if ($SplatArgs.Count -gt 0) { $SplatArgs.Values | Select-Object -First 1 } else { '' }
    # Get workflow name from positional args
    $raw = if ($args.Count -gt 1) { $args[1] } else { $wfName }
    $runScript = Join-Path $ScriptsDir 'workflow-run.ps1'
    if ($raw -and (Test-Path $runScript)) {
        & $runScript -WorkflowName $raw
    } else {
        Write-Host "  Usage: dotbot run <workflow-name>" -ForegroundColor Yellow
    }
}

switch ($Command) {
    "init" { Invoke-Init }
    "workflow" { Invoke-Workflow }
    "registry" { Invoke-Registry }
    "run" { Invoke-Run }
    "resume" {
        Write-Host ""
        Write-Host "  'dotbot resume' is not yet supported." -ForegroundColor Yellow
        Write-Host "  Please use 'dotbot run <workflow-name>' instead." -ForegroundColor Yellow
        Write-Host ""
    }
    "list" { Invoke-List }
    "profiles" { Invoke-List }  # backward compat
    "status" { Invoke-Status }
    "doctor" { & (Join-Path $ScriptsDir 'doctor.ps1') @SplatArgs }
    "update" { Invoke-Update }
    "help" { Show-Help }
    "--help" { Show-Help }
    "-h" { Show-Help }
    $null { Show-Help }
    default {
        Write-Host ""
        Write-Host "  ✗ Unknown command: $Command" -ForegroundColor Red
        Write-Host "    Run 'dotbot help' for available commands" -ForegroundColor Yellow
        Write-Host ""
    }
}
'@
    Set-Content -Path $cliScript -Value $cliContent -Force
    Set-ExecutablePermission -FilePath $cliScript
    Write-Success "Created CLI at: $cliScript"

    # On Unix, create a bash shim so 'dotbot' works without the .ps1 extension
    Initialize-PlatformVariables
    if (-not $IsWindows) {
        $bashShim = Join-Path $BinDir "dotbot"
        $bashShimContent = @'
#!/usr/bin/env bash
# dotbot CLI shim — delegates to the PowerShell wrapper
exec pwsh -NoProfile -File "$(dirname "$0")/dotbot.ps1" "$@"
'@
        Set-Content -Path $bashShim -Value $bashShimContent -Force -NoNewline
        Set-ExecutablePermission -FilePath $bashShim
        Write-Success "Created bash shim at: $bashShim"
    }
}

# Add to PATH
if (-not $DryRun) {
    Add-ToPath -Directory $BinDir
}

# Show completion message
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  ✓ Installation Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Platform: $(Get-PlatformName)" -ForegroundColor Gray
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  NEXT STEPS" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    1. Restart your terminal" -ForegroundColor White
Write-Host "    2. Navigate to your project: cd your-project" -ForegroundColor White
Write-Host "    3. Initialize dotbot: dotbot init" -ForegroundColor White
Write-Host ""
