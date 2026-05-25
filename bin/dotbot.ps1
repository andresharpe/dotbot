#!/usr/bin/env pwsh
# dotbot CLI — canonical entry point inside a dotbot checkout.
#
# This script trusts its own location: $DotbotBase is two directories up
# from the script. The env-var-aware PATH shim (bin/shim/*) is the layer
# that routes $env:DOTBOT_HOME to the right tree; once it has routed,
# this CLI does not consult DOTBOT_HOME again.
#
# Reset strict mode — callers (e.g. setup scripts) may set
# Set-StrictMode -Version Latest which breaks intrinsic .Count
Set-StrictMode -Off

$WrapperPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
try {
    $wrapperItem = Get-Item -LiteralPath $WrapperPath -ErrorAction Stop
    if ($wrapperItem.LinkType -and $wrapperItem.Target) {
        $targetPath = $wrapperItem.Target
        if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
            $targetPath = Join-Path (Split-Path -Parent $wrapperItem.FullName) $targetPath
        }
        $WrapperPath = $targetPath
    }
} catch { }

$DotbotBase = Split-Path -Parent (Split-Path -Parent $WrapperPath)
Import-Module (Join-Path $DotbotBase "src" "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$ScriptsDir = Join-Path $DotbotBase "src" "cli"

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
    Write-DotbotLabel "    runtime-start     " "Start the project's HTTP runtime in the foreground"
    Write-DotbotLabel "    runtime-status    " "Show runtime PID, URL, and active workflow runs"
    Write-DotbotLabel "    prune-branches    " "Delete stale workflow/* and task/* branches"
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

function Invoke-List {
    $workflowsDir = Join-Path $DotbotBase "content" "workflows"
    $stacksDir = Join-Path $DotbotBase "content" "stacks"

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
    Write-DotbotCommand "cd $DotbotBase"
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
        'add'      { Join-Path $ScriptsDir 'workflow-add.ps1' }
        'remove'   { Join-Path $ScriptsDir 'workflow-remove.ps1' }
        'list'     { Join-Path $ScriptsDir 'workflow-list.ps1' }
        'scaffold' { Join-Path $ScriptsDir 'workflow-scaffold.ps1' }
        default    { $null }
    }
    if ($wfScript -and (Test-Path $wfScript)) {
        if ($wfExtra.Count -gt 0) { & $wfScript $wfName @wfExtra } else { & $wfScript $wfName }
    } else {
        Write-DotbotWarning "Usage: dotbot workflow [add|remove|list|scaffold] [name] [--Force]"
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
    "status" { & (Join-Path $ScriptsDir 'status.ps1') @SplatArgs }
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
    "runtime-start"  { & (Join-Path $ScriptsDir 'runtime-start.ps1')  @SplatArgs }
    "runtime-status" { & (Join-Path $ScriptsDir 'runtime-status.ps1') @SplatArgs }
    "prune-branches" { & (Join-Path $ScriptsDir 'prune-branches.ps1') @SplatArgs }
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
