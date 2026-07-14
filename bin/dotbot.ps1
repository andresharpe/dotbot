#!/usr/bin/env pwsh
# dotbot CLI — canonical entry point inside a dotbot checkout.
#
# This script normally trusts its own location: $DotbotBase is two directories
# up from the script. When invoked inside a project with .bot/runtime/,
# that project-local checkout becomes the effective base for this process.
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

function Find-ProjectRuntimeBase {
    param([string]$StartDir)

    if ([string]::IsNullOrWhiteSpace($StartDir)) { return $null }

    try {
        $dir = [System.IO.Path]::GetFullPath($StartDir)
    } catch {
        return $null
    }

    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $botDir = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $botDir) {
            $candidate = Join-Path $botDir 'runtime'
            $candidateCli = Join-Path $candidate 'bin' 'dotbot.ps1'
            $candidateContent = Join-Path $candidate 'content' 'workspace-template'
            if ((Test-Path -LiteralPath $candidateCli -PathType Leaf) -and
                (Test-Path -LiteralPath $candidateContent -PathType Container)) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
            return $null
        }

        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $null }

        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

$ProjectRuntimeBase = Find-ProjectRuntimeBase -StartDir (Get-Location).Path
if (-not [string]::IsNullOrWhiteSpace($ProjectRuntimeBase)) {
    if (-not [string]::IsNullOrWhiteSpace($env:DOTBOT_HOME)) {
        $env:DOTBOT_MACHINE_HOME = $env:DOTBOT_HOME
    }
    $DotbotBase = $ProjectRuntimeBase
    $env:DOTBOT_HOME = $ProjectRuntimeBase
}

Import-Module (Join-Path $DotbotBase "src" "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$ScriptsDir = Join-Path $DotbotBase "src" "cli"

# Import common functions
Import-Module (Join-Path $ScriptsDir "Platform-Functions.psm1") -Force

$RawArgs = @($args)
$FilteredArgs = @()
foreach ($arg in $RawArgs) {
    if ($arg -in @('-y', '--yes')) {
        $env:DOTBOT_ASSUME_YES = '1'
        continue
    }
    $FilteredArgs += $arg
}

$Command = $FilteredArgs[0]
[array]$SubArgs = if ($FilteredArgs.Count -gt 1) { $FilteredArgs[1..($FilteredArgs.Count-1)] } else { @() }

# Convert CLI args to a hashtable for proper named-parameter splatting.
# Array splatting only does positional binding; hashtable splatting is
# required for named parameters like -Workflow / -Stack.
$SplatArgs = @{}
if ($FilteredArgs.Count -gt 1) {
    $raw = $FilteredArgs[1..($FilteredArgs.Count-1)]
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
    Write-DotbotLabel "    workflow run      " "Run/rerun a workflow"
    Write-DotbotLabel "    install runtime   " "Install runtime into an existing project"
    Write-DotbotLabel "    install content   " "Install agent, prompt, or skill content"
    Write-DotbotLabel "    run               " "Run/rerun a workflow"
    Write-DotbotLabel "    tasks run         " "Run a workflow-agnostic task runner (drains pending todo tasks)"
    Write-DotbotLabel "    tasks stop        " "Stop the workflow-agnostic task runner"
    Write-DotbotLabel "    resume            " "Resume a paused workflow"
    Write-DotbotLabel "    list              " "List available workflows and stacks"
    Write-DotbotLabel "    status            " "Show installation status"
    Write-DotbotLabel "    go                " "Launch the project runtime + dashboard"
    Write-DotbotLabel "    registry add      " "Add an enterprise extension registry"
    Write-DotbotLabel "    registry list     " "List registered extension registries"
    Write-DotbotLabel "    registry remove   " "Remove an extension registry"
    Write-DotbotLabel "    update            " "Update global installation"
    Write-DotbotLabel "    studio            " "Launch visual configuration studio"
    Write-DotbotLabel "    doctor            " "Scan project for health issues"
    Write-DotbotLabel "    serve             " "Start only the low-level HTTP runtime in the foreground"
    Write-DotbotLabel "    runtime-status    " "Show runtime PID, URL, and active workflow runs"
    Write-DotbotLabel "    prune-branches    " "Delete stale workflow/* and task/* branches"
    Write-DotbotLabel "    help              " "Show this help message"
    Write-BlankLine
    Write-DotbotSection "GLOBAL OPTIONS"
    Write-DotbotLabel "    -y, --yes         " "Answer yes to confirmation prompts"
    Write-BlankLine
}

function Test-CliSwitch {
    param([string[]]$Names)

    foreach ($name in $Names) {
        if ($SplatArgs.ContainsKey($name) -and [bool]$SplatArgs[$name]) {
            return $true
        }
    }
    return $false
}

function ConvertTo-SplatArg {
    param(
        [string[]]$Tokens,
        [string[]]$PositionalNames = @()
    )

    $splat = @{}
    $positional = @()
    $i = 0
    while ($i -lt $Tokens.Count) {
        if ($Tokens[$i] -match '^--?(.+)$') {
            $pname = $Matches[1]
            if (($i + 1) -lt $Tokens.Count -and $Tokens[$i + 1] -notmatch '^--?') {
                $splat[$pname] = $Tokens[$i + 1]
                $i += 2
            } else {
                $splat[$pname] = $true
                $i++
            }
        } else {
            $positional += $Tokens[$i]
            $i++
        }
    }

    for ($j = 0; $j -lt [Math]::Min($positional.Count, $PositionalNames.Count); $j++) {
        $splat[$PositionalNames[$j]] = $positional[$j]
    }

    if ($positional.Count -gt $PositionalNames.Count) {
        $unexpected = $positional[$PositionalNames.Count..($positional.Count - 1)] -join ', '
        Write-DotbotError "Unexpected argument(s): $unexpected"
        exit 1
    }

    return $splat
}

function Get-RequestedDashboardPort {
    if ($SplatArgs.ContainsKey('Port')) { return [int]$SplatArgs['Port'] }
    if ($SplatArgs.ContainsKey('port')) { return [int]$SplatArgs['port'] }
    return 0
}

function Invoke-Init {
    $registryManagerModule = Join-Path $ScriptsDir "RegistryManager.psm1"
    if (Test-Path $registryManagerModule) {
        Import-Module $registryManagerModule -Force -DisableNameChecking
        Update-StaleRegistries -DotbotBase $DotbotBase
    }
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
                $manifestPath = Join-Path $d.FullName "manifest.json"
                if (-not (Test-Path $manifestPath)) { $manifestPath = Join-Path $d.FullName "workflow.json" }
                $desc = ""
                if (Test-Path $manifestPath) {
                    try {
                        $meta = Get-Content $manifestPath -Raw | ConvertFrom-Json
                        if ($meta.description) { $desc = $meta.description }
                    } catch {}
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
                $manifestPath = Join-Path $d.FullName "manifest.json"
                $desc = ""; $extends = ""
                if (Test-Path $manifestPath) {
                    try {
                        $meta = Get-Content $manifestPath -Raw | ConvertFrom-Json
                        if ($meta.description) { $desc = $meta.description }
                        if ($meta.extends) { $extends = $meta.extends }
                    } catch {}
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
    Write-DotbotWarning "(no reinstall step needed — `$env:DOTBOT_HOME tracks this checkout live)"
    Write-BlankLine
}

function Get-WorkflowRunInvocation {
    param([object[]]$RunArgs)

    $workflowName = ''
    $runSplat = @{}
    $i = 0
    while ($i -lt $RunArgs.Count) {
        $token = [string]$RunArgs[$i]
        if ($token -match '^--?(.+)$') {
            $rawName = $Matches[1]
            $name = ($rawName -replace '-', '').ToLowerInvariant()
            switch ($name) {
                'watch' {
                    $runSplat['Watch'] = $true
                    $i++
                }
                'noautoruntime' {
                    $runSplat['NoAutoRuntime'] = $true
                    $i++
                }
                'pollintervalms' {
                    if (($i + 1) -lt $RunArgs.Count) {
                        $runSplat['PollIntervalMs'] = [int]$RunArgs[$i + 1]
                        $i += 2
                    } else {
                        $runSplat['PollIntervalMs'] = 1000
                        $i++
                    }
                }
                default {
                    if (($i + 1) -lt $RunArgs.Count -and [string]$RunArgs[$i + 1] -notmatch '^--?') {
                        $runSplat[$rawName] = $RunArgs[$i + 1]
                        $i += 2
                    } else {
                        $runSplat[$rawName] = $true
                        $i++
                    }
                }
            }
        } else {
            if (-not $workflowName) { $workflowName = $token }
            $i++
        }
    }

    return @{
        WorkflowName = $workflowName
        Parameters   = $runSplat
    }
}

function Invoke-Workflow {
    $wfSubCmd = if ($SubArgs.Count -gt 0) { $SubArgs[0] } else { 'list' }
    $wfName = if ($SubArgs.Count -gt 1) { $SubArgs[1] } else { '' }
    [string[]]$wfExtra = @()
    if ($SubArgs.Count -gt 2) { $wfExtra = @($SubArgs[2..($SubArgs.Count-1)]) }
    if ($wfSubCmd -eq 'run') {
        $runScript = Join-Path $ScriptsDir 'workflow-run.ps1'
        $runArgs = @($wfName) + $wfExtra
        $invocation = Get-WorkflowRunInvocation -RunArgs $runArgs
        if ($invocation.WorkflowName -and (Test-Path $runScript)) {
            $runParams = $invocation.Parameters
            $global:LASTEXITCODE = 0
            & $runScript -WorkflowName $invocation.WorkflowName @runParams
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } else {
            Write-DotbotWarning "Usage: dotbot workflow run <workflow-name> [--watch] [--poll-interval-ms <ms>] [--no-auto-runtime]"
        }
        return
    }
    $wfScript = switch ($wfSubCmd) {
        'add'      { Join-Path $ScriptsDir 'workflow-add.ps1' }
        'remove'   { Join-Path $ScriptsDir 'workflow-remove.ps1' }
        'list'     { Join-Path $ScriptsDir 'workflow-list.ps1' }
        'scaffold' { Join-Path $ScriptsDir 'workflow-scaffold.ps1' }
        default    { $null }
    }
    if ($wfScript -and (Test-Path $wfScript)) {
        $wfRest = if ($SubArgs.Count -gt 1) { @($SubArgs[1..($SubArgs.Count - 1)]) } else { @() }
        $wfSplat = ConvertTo-SplatArg -Tokens $wfRest -PositionalNames @('Name')
        & $wfScript @wfSplat
    } else {
        Write-DotbotWarning "Usage: dotbot workflow [add|remove|list|scaffold|run] [name] [--Force]"
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

function Invoke-Install {
    $installSubCmd = ''
    $contentSplat = @{}
    $runtimeSplat = @{}
    $contentPositionals = @()
    $i = 0
    while ($i -lt $SubArgs.Count) {
        $token = [string]$SubArgs[$i]
        if ($token -match '^--?(.+)$') {
            $rawFlagName = $Matches[1]
            $flagName = $rawFlagName.ToLowerInvariant()
            if ($flagName -in @('from','version')) {
                if (($i + 1) -ge $SubArgs.Count -or [string]$SubArgs[$i + 1] -match '^--?') {
                    Write-DotbotWarning "Missing value for --$flagName"
                    return
                }
                if ($flagName -eq 'from') {
                    $contentSplat['From'] = $SubArgs[$i + 1]
                    $runtimeSplat['From'] = $SubArgs[$i + 1]
                }
                if ($flagName -eq 'version') {
                    $contentSplat['Version'] = $SubArgs[$i + 1]
                }
                $i += 2
                continue
            }
            if ($flagName -in @('global','g','force')) {
                if ($flagName -in @('global','g')) { $contentSplat['GlobalInstall'] = $true }
                if ($flagName -eq 'force') {
                    $contentSplat['Force'] = $true
                    $runtimeSplat['Force'] = $true
                }
                $i++
                continue
            }

            if (($i + 1) -lt $SubArgs.Count -and [string]$SubArgs[$i + 1] -notmatch '^--?') {
                $runtimeSplat[$rawFlagName] = $SubArgs[$i + 1]
                $i += 2
            } else {
                $runtimeSplat[$rawFlagName] = $true
                $i++
            }
            continue
        }

        if (-not $installSubCmd) {
            $installSubCmd = $token
        } else {
            $contentPositionals += $token
        }
        $i++
    }

    if ($installSubCmd -eq 'runtime') {
        $installScript = Join-Path $ScriptsDir 'install-runtime.ps1'
        if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
            Write-DotbotError "Runtime install script not found"
            return
        }

        & $installScript @runtimeSplat
        return
    }

    if ($installSubCmd -in @('agent','agents','prompt','prompts','skill','skills')) {
        $installScript = Join-Path $ScriptsDir 'install-content.ps1'
        if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
            Write-DotbotError "Content install script not found"
            return
        }

        if ($contentPositionals.Count -gt 0 -and -not $contentSplat.ContainsKey('Source')) {
            $contentSplat['Source'] = $contentPositionals[0]
        }

        & $installScript -Type $installSubCmd @contentSplat
        return
    }

    Write-DotbotWarning "Usage: dotbot install runtime [--from <dotbot-checkout>]"
    Write-DotbotCommand "       dotbot install [--global] <agent|prompt|skill> <name|path|registry/path|github-url> [--version <vN>] [--force]"
    Write-DotbotCommand "       dotbot install skill --from github.com/owner/repo/skills/name:v2 --global"
}

function Invoke-Run {
    $registryManagerModule = Join-Path $ScriptsDir "RegistryManager.psm1"
    if (Test-Path $registryManagerModule) {
        Import-Module $registryManagerModule -Force -DisableNameChecking
        Update-StaleRegistries -DotbotBase $DotbotBase
    }
    $runScript = Join-Path $ScriptsDir 'workflow-run.ps1'
    $invocation = Get-WorkflowRunInvocation -RunArgs $SubArgs
    if ($invocation.WorkflowName -and (Test-Path $runScript)) {
        $runParams = $invocation.Parameters
        $global:LASTEXITCODE = 0
        & $runScript -WorkflowName $invocation.WorkflowName @runParams
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        Write-DotbotWarning "Usage: dotbot run <workflow-name> [--watch] [--poll-interval-ms <ms>] [--no-auto-runtime]"
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

function Find-DotbotProjectBotDir {
    param([string]$StartDir)

    $dir = [System.IO.Path]::GetFullPath($StartDir)
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $candidate = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { break }

        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

function Test-UIServerAlive {
    # Liveness probe (NOT a synchronization wait): is a UI server already serving
    # for this project? Reads the published port and does a short HTTP GET. The
    # short -TimeoutSec is a network read budget, not a lock timeout. server.ps1
    # publishes ui-port only after its listener binds, so a readable port that
    # responds means a live UI.
    param([Parameter(Mandatory)][string]$BotRoot)
    $uiPortFile = Join-Path $BotRoot ".control/ui-port"
    if (-not (Test-Path -LiteralPath $uiPortFile)) { return @{ alive = $false } }
    try {
        $port = [int]((Get-Content -LiteralPath $uiPortFile -Raw -ErrorAction Stop).Trim())
        if ($port -le 0) { return @{ alive = $false } }
        $resp = Invoke-WebRequest -Uri "http://localhost:$port/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ([int]$resp.StatusCode -eq 200) { return @{ alive = $true; port = $port } }
        return @{ alive = $false }
    } catch {
        return @{ alive = $false }
    }
}

function Invoke-Go {
    $botDir = Find-DotbotProjectBotDir -StartDir (Get-Location).Path
    if (-not $botDir) {
        Write-DotbotError "Project is not initialized."
        Write-DotbotCommand "Run 'dotbot init' from the project root first."
        return
    }

    $serverScript = Join-Path $DotbotBase 'src/ui/server.ps1'
    if (-not (Test-Path -LiteralPath $serverScript)) {
        Write-DotbotError "Dashboard server not found at $serverScript"
        return
    }

    # If a UI server is already serving this project, attach to it instead of
    # starting a second one that would clobber the shared ui-port file. The
    # model is one UI per project showing all runs. (Cold-start ties — two
    # `dotbot go` launched in the same instant with none running — still resolve
    # to a single live listener: the OS rejects the second bind with a clear
    # error rather than corrupting state.)
    $existingUI = Test-UIServerAlive -BotRoot $botDir
    if ($existingUI.alive) {
        Write-Success ("Dashboard already running at http://localhost:{0}" -f $existingUI.port)
        Write-DotbotCommand "Attaching to the existing UI (one dashboard shows all runs)."
        if (Test-CliSwitch -Names @('Open', 'open')) {
            try { Start-Process "http://localhost:$($existingUI.port)" } catch { $null = $_ }
        }
        return
    }

    $serverArgs = @{}
    if ($SplatArgs.ContainsKey('Port')) {
        $serverArgs['Port'] = $SplatArgs['Port']
    } elseif ($SplatArgs.ContainsKey('port')) {
        $serverArgs['Port'] = $SplatArgs['port']
    }
    $openBrowser = Test-CliSwitch -Names @('Open', 'open')
    if ($openBrowser) {
        $serverArgs['OpenBrowser'] = $true
    }

    $runtimeStart = $null
    $runtimeStartedHere = $false
    $startRuntime = -not (Test-CliSwitch -Names @('NoRuntime', 'no-runtime', 'noruntime'))
    if ($startRuntime) {
        $runtimePsd1 = Join-Path $DotbotBase 'src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1'
        if (-not (Test-Path -LiteralPath $runtimePsd1)) {
            Write-DotbotError "Dotbot.Runtime module not found at $runtimePsd1"
            return
        }

        Import-Module $runtimePsd1 -DisableNameChecking -Force

        $runtimeArgs = @{ BotRoot = $botDir }
        $requestedDashboardPort = Get-RequestedDashboardPort
        if ($requestedDashboardPort -gt 0) {
            do {
                $candidateRuntimePort = Find-AvailableRuntimePort
            } while ($candidateRuntimePort -eq $requestedDashboardPort)
            $runtimeArgs['Port'] = $candidateRuntimePort
        }

        $runtimeStart = Start-DotbotRuntime @runtimeArgs
        $runtimeStartedHere = -not [bool]$runtimeStart.attached
        if ($runtimeStart.attached) {
            Write-DotbotCommand ("Runtime already running at {0} (PID {1})." -f $runtimeStart.url, $runtimeStart.pid)
        } else {
            Write-Success ("Runtime ready at {0}" -f $runtimeStart.url)
        }
    }

    $projectRoot = Split-Path -Parent $botDir
    Push-Location $projectRoot
    try {
        & $serverScript @serverArgs
    } finally {
        Pop-Location
        if ($runtimeStartedHere -and $runtimeStart -and $runtimeStart.listener) {
            Stop-DotbotRuntime -BotRoot $botDir -Listener $runtimeStart.listener -ControlPlaneRegistration $runtimeStart.control_plane -EventConsumer $runtimeStart.events_consumer -ErrorAction SilentlyContinue
        }
    }
}

switch ($Command) {
    "init" { Invoke-Init }
    "workflow" { Invoke-Workflow }
    "registry" { Invoke-Registry }
    "install" { Invoke-Install }
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
    "go" { Invoke-Go }
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
    "serve"          { & (Join-Path $ScriptsDir 'serve.ps1')          @SplatArgs }
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
