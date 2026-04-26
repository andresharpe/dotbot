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
Import-Module (Join-Path $ScriptDir "..\workflows\default\systems\runtime\modules\DotBotTheme.psm1") -Force -DisableNameChecking

Write-Status "Installing dotbot to $BaseDir"

# Check if source and destination are the same
$resolvedSource = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
$resolvedBase = if (Test-Path $BaseDir) { (Resolve-Path $BaseDir).Path.TrimEnd('\', '/') } else { $null }

if ($resolvedBase -and ($resolvedSource -eq $resolvedBase)) {
    Write-Success "Already running from target installation directory"
    Write-Success "dotbot is installed at: $BaseDir"
} else {
    if ($DryRun) {
        Write-DotbotWarning "Would copy files from: $SourceDir"
        Write-DotbotWarning "Would copy to: $BaseDir"
    } else {
        # Create base directory
        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        }
        
        # Allowlist: only copy directories and files needed at runtime.
        # Everything else (server, ideas, tests, docs, assets, etc.) stays in the repo.
        $allowedDirs = @("scripts", "workflows", "stacks")
        $allowedFiles = @("version.json", "dotbot.psm1", "dotbot.psd1", "install.ps1", "install-remote.ps1")

        foreach ($dirName in $allowedDirs) {
            $src = Join-Path $SourceDir $dirName
            if (Test-Path $src) {
                $dest = Join-Path $BaseDir $dirName
                if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
                Copy-Item -Path $src -Destination $dest -Recurse -Force
            }
        }

        foreach ($fileName in $allowedFiles) {
            $src = Join-Path $SourceDir $fileName
            if (Test-Path $src) {
                Copy-Item -Path $src -Destination (Join-Path $BaseDir $fileName) -Force
            }
        }

        # Copy only deployable studio-ui files (server.ps1, module, static/)
        $editorSrc = Join-Path $SourceDir "studio-ui"
        if (Test-Path $editorSrc) {
            $editorDest = Join-Path $BaseDir "studio-ui"
            if (Test-Path $editorDest) { Remove-Item -Path $editorDest -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $editorDest | Out-Null

            # Copy server script and API module
            foreach ($file in @("server.ps1", "StudioAPI.psm1")) {
                $src = Join-Path $editorSrc $file
                if (Test-Path $src) {
                    Copy-Item -Path $src -Destination (Join-Path $editorDest $file) -Force
                }
            }

            # Copy static/ directory (built client assets)
            $staticSrc = Join-Path $editorSrc "static"
            if (Test-Path $staticSrc) {
                Copy-Item -Path $staticSrc -Destination (Join-Path $editorDest "static") -Recurse -Force
            } else {
                Write-DotbotWarning "studio-ui/static/ not found — the editor UI requires built assets. Run 'npm run build' in studio-ui/ first."
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
} catch { Write-DotbotCommand "Parse skipped: $_" }
$env:DOTBOT_VERSION = $DotbotVersion

function Show-Help {
    Write-DotbotBanner -Title "D O T B O T   v$DotbotVersion" -Subtitle "Autonomous Development System"
    Write-DotbotSection "COMMANDS"
    Write-DotbotLabel "    init              " "Initialize .bot in current project"
    Write-DotbotLabel "    workflow add      " "Add a workflow to existing project"
    Write-DotbotLabel "    workflow remove   " "Remove an installed workflow"
    Write-DotbotLabel "    workflow list     " "List installed workflows"
    Write-DotbotLabel "    run               " "Run/rerun a workflow"
    Write-DotbotLabel "    tasks run         " "Run a workflow-agnostic task runner (drains pending todo tasks)"
    Write-DotbotLabel "    tasks stop        " "Stop the workflow-agnostic task runner"
    Write-DotbotLabel "    resume            " "Resume a paused workflow"
    Write-DotbotLabel "    list              " "List available workflows and stacks"
    Write-DotbotLabel "    status            " "Show installation status"
    Write-DotbotLabel "    registry add      " "Add an enterprise extension registry"
    Write-DotbotLabel "    registry list     " "List registered extension registries"
    Write-DotbotLabel "    registry remove   " "Remove an extension registry"
    Write-DotbotLabel "    update            " "Update global installation"
    Write-DotbotLabel "    studio            " "Launch visual configuration studio"
    Write-DotbotLabel "    doctor            " "Scan project for health issues"
    Write-DotbotLabel "    help              " "Show this help message"
    Write-BlankLine
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
        Write-DotbotError "Init script not found"
    }
}

function Invoke-Status {
    Write-DotbotBanner -Title "D O T B O T   v$DotbotVersion" -Subtitle "Status"

    # Check global installation
    Write-DotbotSection "GLOBAL INSTALLATION"
    Write-DotbotLabel "    Status:   " "✓ Installed" -ValueType Success
    Write-DotbotLabel "    Location: " "$DotbotBase"
    Write-BlankLine

    # Check project installation
    $botDir = Join-Path (Get-Location) ".bot"
    Write-DotbotSection "PROJECT INSTALLATION"

    if (Test-Path $botDir) {
        Write-DotbotLabel "    Status:   " "✓ Enabled" -ValueType Success
        Write-DotbotLabel "    Location: " "$botDir"

        # Count components
        $mcpDir = Join-Path $botDir "systems\mcp"
        $uiDir = Join-Path $botDir "systems\ui"
        $promptsDir = Join-Path $botDir "recipes"

        if (Test-Path $mcpDir) {
            Write-DotbotLabel "    MCP:      " "✓ Available" -ValueType Success
        }
        if (Test-Path $uiDir) {
            Write-DotbotLabel "    UI:       " "✓ Available (default port 8686)" -ValueType Success
        }
        if (Test-Path $promptsDir) {
            $agentCount = (Get-ChildItem -Path (Join-Path $promptsDir "agents") -Directory -ErrorAction SilentlyContinue).Count
            $skillCount = (Get-ChildItem -Path (Join-Path $promptsDir "skills") -Directory -ErrorAction SilentlyContinue).Count
            Write-DotbotLabel "    Agents:   " "$agentCount"
            Write-DotbotLabel "    Skills:   " "$skillCount"
        }
        Write-BlankLine
    } else {
        Write-DotbotLabel "    Status:   " "✗ Not initialized" -ValueType Error
        Write-BlankLine
        Write-DotbotWarning "Run 'dotbot init' to add dotbot to this project"
        Write-BlankLine
    }
}

function Invoke-List {
    $workflowsDir = Join-Path $DotbotBase "workflows"
    $stacksDir = Join-Path $DotbotBase "stacks"

    Write-DotbotBanner -Title "D O T B O T   v$DotbotVersion" -Subtitle "Available Workflows & Stacks"

    # Workflows
    if (Test-Path $workflowsDir) {
        $wfDirs = @(Get-ChildItem -Path $workflowsDir -Directory)
        if ($wfDirs.Count -gt 0) {
            Write-DotbotSection "WORKFLOWS"
            foreach ($d in $wfDirs) {
                $yamlPath = Join-Path $d.FullName "manifest.yaml"
                if (-not (Test-Path $yamlPath)) { $yamlPath = Join-Path $d.FullName "workflow.yaml" }
                $desc = ""
                if (Test-Path $yamlPath) {
                    Get-Content $yamlPath | ForEach-Object {
                        if ($_ -match '^\s*description:\s*(.+)$') { $desc = $Matches[1].Trim() }
                    }
                }
                Write-DotbotLabel "    $($d.Name.PadRight(24))" "$desc"
            }
            Write-BlankLine
        }
    }

    # Stacks
    if (Test-Path $stacksDir) {
        $stDirs = @(Get-ChildItem -Path $stacksDir -Directory)
        if ($stDirs.Count -gt 0) {
            Write-DotbotSection "STACKS (composable)"
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
                Write-DotbotLabel "    $($label.PadRight(36))" "$desc"
            }
            Write-BlankLine
        }
    }

    Write-DotbotSection "USAGE"
    Write-DotbotCommand "dotbot init --stack dotnet"
    Write-DotbotCommand "dotbot init --workflow start-from-jira --stack dotnet-blazor"
    Write-BlankLine
}

function Invoke-Update {
    Write-BlankLine
    Write-DotbotWarning "To update dotbot:"
    Write-BlankLine
    Write-DotbotCommand "cd ~/dotbot"
    Write-DotbotCommand "git pull"
    Write-DotbotCommand "./install.ps1"
    Write-BlankLine
}

function Invoke-Workflow {
    $wfSubCmd = if ($SubArgs.Count -gt 0) { $SubArgs[0] } else { 'list' }
    $wfName = if ($SubArgs.Count -gt 1) { $SubArgs[1] } else { '' }
    [string[]]$wfExtra = @()
    if ($SubArgs.Count -gt 2) { $wfExtra = @($SubArgs[2..($SubArgs.Count-1)]) }
    $wfScript = switch ($wfSubCmd) {
        'add'    { Join-Path $ScriptsDir 'workflow-add.ps1' }
        'remove' { Join-Path $ScriptsDir 'workflow-remove.ps1' }
        'list'   { Join-Path $ScriptsDir 'workflow-list.ps1' }
        default  { $null }
    }
    if ($wfScript -and (Test-Path $wfScript)) {
        if ($wfExtra.Count -gt 0) { & $wfScript $wfName @wfExtra } else { & $wfScript $wfName }
    } else {
        Write-DotbotWarning "Usage: dotbot workflow [add|remove|list] [name] [--Force]"
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
        'update' { Join-Path $ScriptsDir 'registry-update.ps1' }
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
        } elseif ($regSubCmd -eq 'update') {
            if ($positional.Count -ge 1) { $regSplat['Name'] = $positional[0] }
        }

        & $regScript @regSplat
    } else {
        Write-DotbotWarning "Usage: dotbot registry [add|list|update|remove] ..."
        Write-DotbotCommand "  add    <name> <source> [--branch main] [--force]"
        Write-DotbotCommand "  list"
        Write-DotbotCommand "  update [name] [--force]"
        Write-DotbotCommand "  remove <name>"
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
        Write-DotbotWarning "Usage: dotbot run <workflow-name>"
    }
}

function Invoke-Tasks {
    $sub = if ($SubArgs.Count -gt 0) { $SubArgs[0] } else { '' }
    switch ($sub) {
        'run'  {
            $script = Join-Path $ScriptsDir 'tasks-run.ps1'
            if (Test-Path $script) { & $script } else { Write-DotbotError "tasks-run.ps1 not found" }
        }
        'stop' {
            $script = Join-Path $ScriptsDir 'tasks-stop.ps1'
            if (Test-Path $script) { & $script } else { Write-DotbotError "tasks-stop.ps1 not found" }
        }
        default {
            Write-DotbotWarning "Usage: dotbot tasks [run|stop]"
            Write-DotbotCommand "  run    Launch a workflow-agnostic task runner that drains pending todo tasks"
            Write-DotbotCommand "  stop   Signal stop to the workflow-agnostic task runner"
        }
    }
}

switch ($Command) {
    "init" { Invoke-Init }
    "workflow" { Invoke-Workflow }
    "registry" { Invoke-Registry }
    "run" { Invoke-Run }
    "tasks" { Invoke-Tasks }
    "resume" {
        Write-BlankLine
        Write-DotbotWarning "'dotbot resume' is not yet supported."
        Write-DotbotWarning "Please use 'dotbot run <workflow-name>' instead."
        Write-BlankLine
    }
    "list" { Invoke-List }
    "profiles" { Invoke-List }  # backward compat
    "status" { Invoke-Status }
    "studio" {
        $studioDir = Join-Path $DotbotBase "studio-ui"
        $serverScript = Join-Path $studioDir "server.ps1"
        $portFile = Join-Path $DotbotBase ".studio-port"

        if (-not (Test-Path $serverScript)) {
            Write-BlankLine
            Write-DotbotError "Studio not found."
            Write-DotbotWarning "Run 'dotbot update' to install the studio"
            Write-BlankLine
            break
        }

        # Check if studio is already running
        if (Test-Path $portFile) {
            try {
                $portInfo = Get-Content $portFile -Raw | ConvertFrom-Json
                $existingPort = $portInfo.port
                $existingPid = $portInfo.pid
                # Verify the process is still alive
                $proc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -match 'pwsh|powershell') {
                    Write-BlankLine
                    Write-Success "Studio already running at http://localhost:$existingPort (PID $existingPid)"
                    Write-Status "Opening browser..."
                    Write-BlankLine
                    Start-Process "http://localhost:$existingPort"
                    break
                }
                # Stale port file — process is gone
                Remove-Item $portFile -Force -ErrorAction SilentlyContinue
            } catch {
                Remove-Item $portFile -Force -ErrorAction SilentlyContinue
            }
        }

        & pwsh -NoProfile -File $serverScript
    }
    "doctor" { & (Join-Path $ScriptsDir 'doctor.ps1') @SplatArgs }
    "update" { Invoke-Update }
    "help" { Show-Help }
    "--help" { Show-Help }
    "-h" { Show-Help }
    $null { Show-Help }
    default {
        Write-BlankLine
        Write-DotbotError "Unknown command: $Command"
        Write-DotbotWarning "Run 'dotbot help' for available commands"
        Write-BlankLine
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

# Ensure powershell-yaml module is available
if (-not $DryRun) {
    if (-not (Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue)) {
        Write-Status "Installing powershell-yaml module..."
        Install-Module -Name powershell-yaml -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
        Write-Success "powershell-yaml module installed"
    } else {
        Write-Success "powershell-yaml module already installed"
    }
}

# Add to PATH
if (-not $DryRun) {
    Add-ToPath -Directory $BinDir
}

# Show completion message
Write-BlankLine
Write-Success "Installation Complete!"
Write-Status "Platform: $(Get-PlatformName)"
Write-BlankLine
Write-DotbotSection "NEXT STEPS"
Write-DotbotCommand "1. Restart your terminal"
Write-DotbotCommand "2. Navigate to your project: cd your-project"
Write-DotbotCommand "3. Initialize dotbot: dotbot init"
Write-BlankLine
