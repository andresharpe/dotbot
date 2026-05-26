#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run (or rerun) an installed workflow.

.DESCRIPTION
    Reads the workflow.yaml tasks section, creates task JSONs in the shared queue
    with the workflow field set, runs preflight checks, and spawns a workflow
    process filtered to this workflow's tasks.

.PARAMETER WorkflowName
    Name of the installed workflow (e.g., "iwg-bs-scoring").
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$WorkflowName,

    [switch]$Watch,

    [ValidateRange(250, 60000)]
    [int]$PollIntervalMs = 1000,

    [switch]$NoAutoRuntime
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src\cli\Platform-Functions.psm1") -Force
Import-Module (Join-Path (Get-DotbotInstallPath) "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1") -Force -DisableNameChecking

# Import manifest utilities
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

function Read-DotbotJsonFile {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Wait-DotbotProcessFile {
    param(
        [Parameter(Mandatory)] [string]$ProcessesDir,
        [Parameter(Mandatory)] [int]$ProcessPid,
        [Parameter(Mandatory)] [string]$RunId,
        [int]$TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $procFiles = @(Get-ChildItem -LiteralPath $ProcessesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)

        foreach ($pf in $procFiles) {
            $proc = Read-DotbotJsonFile -Path $pf.FullName
            if (-not $proc) { continue }
            if (($proc.pid -eq $ProcessPid) -or ($proc.run_id -eq $RunId)) {
                return $proc
            }
        }

        Start-Sleep -Milliseconds 250
    }

    return $null
}

function Get-WorkflowRunTaskSummary {
    param([Parameter(Mandatory)] [string]$RunDir)

    $counts = [ordered]@{
        total       = 0
        todo        = 0
        analysing   = 0
        analysed    = 0
        in_progress = 0
        needs_input = 0
        done        = 0
        skipped     = 0
        failed      = 0
        cancelled   = 0
        other       = 0
    }

    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { return $counts }

    foreach ($file in @(Get-ChildItem -LiteralPath $RunDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'run.json' })) {
        $task = Read-DotbotJsonFile -Path $file.FullName
        if (-not $task) { continue }
        $counts.total++
        switch ([string]$task.status) {
            'todo'        { $counts.todo++ }
            'analysing'   { $counts.analysing++ }
            'analysed'    { $counts.analysed++ }
            'in-progress' { $counts.in_progress++ }
            'needs-input' { $counts.needs_input++ }
            'done'        { $counts.done++ }
            'skipped'     { $counts.skipped++ }
            'failed'      { $counts.failed++ }
            'cancelled'   { $counts.cancelled++ }
            default       { $counts.other++ }
        }
    }

    return $counts
}

function Format-WorkflowRunTaskSummary {
    param([Parameter(Mandatory)] $Counts)

    $parts = @(
        "done $($Counts.done)/$($Counts.total)",
        "todo $($Counts.todo)",
        "analysing $($Counts.analysing)",
        "analysed $($Counts.analysed)",
        "in-progress $($Counts.in_progress)"
    )
    if ($Counts.needs_input -gt 0) { $parts += "needs-input $($Counts.needs_input)" }
    if ($Counts.skipped -gt 0) { $parts += "skipped $($Counts.skipped)" }
    if ($Counts.failed -gt 0) { $parts += "failed $($Counts.failed)" }
    if ($Counts.cancelled -gt 0) { $parts += "cancelled $($Counts.cancelled)" }
    if ($Counts.other -gt 0) { $parts += "other $($Counts.other)" }
    return ($parts -join " | ")
}

function Read-NewProcessActivityEvents {
    param(
        [Parameter(Mandatory)] [string]$ProcessesDir,
        [Parameter(Mandatory)] [string]$ProcessId,
        [int]$Position = 0
    )

    $activityPath = Join-Path $ProcessesDir "$ProcessId.activity.jsonl"
    if (-not (Test-Path -LiteralPath $activityPath -PathType Leaf)) {
        return @{ events = @(); position = 0 }
    }

    try {
        $stream = [System.IO.FileStream]::new($activityPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            try {
                $text = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return @{ events = @(); position = $Position }
    }

    $lines = @($text -split "`n" | Where-Object { $_.Trim() })
    $events = @()
    for ($i = $Position; $i -lt $lines.Count; $i++) {
        try {
            $events += ($lines[$i] | ConvertFrom-Json)
        } catch {
            continue
        }
    }

    return @{ events = $events; position = $lines.Count }
}

function Write-WorkflowWatchEvent {
    param([Parameter(Mandatory)] $Event)

    $message = $null
    if ($Event.PSObject.Properties['message']) { $message = [string]$Event.message }
    elseif ($Event.PSObject.Properties['msg']) { $message = [string]$Event.msg }
    if (-not $message) { return }

    $prefix = if ($Event.PSObject.Properties['phase'] -and $Event.phase) { "[$($Event.phase)] " } else { "" }
    Write-DotbotCommand ("  {0}{1}" -f $prefix, $message)
}

function Stop-DotbotWatchedProcess {
    param(
        [Parameter(Mandatory)] [string]$ProcessesDir,
        [Parameter(Mandatory)] [string]$ProcessId
    )

    $stopFile = Join-Path $ProcessesDir "$ProcessId.stop"
    "stop" | Set-Content -LiteralPath $stopFile -Encoding UTF8
}

function Watch-DotbotWorkflowRun {
    param(
        [Parameter(Mandatory)] [string]$ProcessesDir,
        [Parameter(Mandatory)] [string]$RunDir,
        [Parameter(Mandatory)] [string]$ProcessId,
        [Parameter(Mandatory)] [int]$PollMs
    )

    Write-BlankLine
    Write-DotbotSection "WATCH"
    Write-DotbotLabel "Process:" $ProcessId
    Write-DotbotCommand "Press Ctrl+C to stop the runner."
    Write-BlankLine

    $activityPosition = 0
    $lastStatusLine = $null
    $stopSignalled = $false
    $script:DotbotWorkflowWatchStopRequested = $false

    try {
        [Console]::CancelKeyPress.Add({
            param($sender, $eventArgs)
            $eventArgs.Cancel = $true
            $script:DotbotWorkflowWatchStopRequested = $true
        })
    } catch {
        $null = $_
    }

    while ($true) {
        if ($script:DotbotWorkflowWatchStopRequested -and -not $stopSignalled) {
            Stop-DotbotWatchedProcess -ProcessesDir $ProcessesDir -ProcessId $ProcessId
            Write-DotbotWarning "Stop signal sent to $ProcessId. Waiting for the runner to exit..."
            $stopSignalled = $true
        }

        $procPath = Join-Path $ProcessesDir "$ProcessId.json"
        $proc = Read-DotbotJsonFile -Path $procPath
        if (-not $proc) {
            Write-DotbotWarning "Process file disappeared: $procPath"
            return 1
        }

        $activity = Read-NewProcessActivityEvents -ProcessesDir $ProcessesDir -ProcessId $ProcessId -Position $activityPosition
        $activityPosition = [int]$activity.position
        foreach ($event in @($activity.events)) {
            Write-WorkflowWatchEvent -Event $event
        }

        $counts = Get-WorkflowRunTaskSummary -RunDir $RunDir
        $heartbeat = if ($proc.heartbeat_status) { [string]$proc.heartbeat_status } else { "" }
        $statusLine = "{0} | {1} | {2}" -f $proc.status, (Format-WorkflowRunTaskSummary -Counts $counts), $heartbeat
        if ($statusLine -ne $lastStatusLine) {
            Write-Status $statusLine
            $lastStatusLine = $statusLine
        }

        if ($proc.status -notin @('starting', 'running')) {
            Write-BlankLine
            switch ([string]$proc.status) {
                'completed' {
                    Write-Success "Workflow process completed."
                    return 0
                }
                'needs-input' {
                    Write-DotbotWarning "Workflow paused for input."
                    return 2
                }
                'stopped' {
                    if ($stopSignalled) {
                        Write-DotbotWarning "Workflow process stopped."
                        return 130
                    }
                    Write-DotbotWarning "Workflow process stopped unexpectedly."
                    return 1
                }
                default {
                    $err = if ($proc.error) { ": $($proc.error)" } else { "" }
                    Write-DotbotError "Workflow process ended with status '$($proc.status)'$err"
                    return 1
                }
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }
}

# resolve through the two-tier registry — project tier (.bot/workflows/)
# takes precedence over the framework tier (.bot/content/workflows/).
$resolved = Find-Workflow -BotRoot $BotDir -Name $WorkflowName
if (-not $resolved.ok) {
    Write-DotbotError "Workflow '$WorkflowName' is not installed."
    Write-DotbotWarning "Installed workflows:"
    foreach ($wf in (Discover-Workflows -BotRoot $BotDir)) {
        Write-Status "- $($wf.name) ($($wf.source))"
    }
    exit 1
}
$wfDir = $resolved.path
$wfSource = $resolved.source
Write-DotbotCommand "Resolved '$WorkflowName' from $wfSource tier ($wfDir)"

# Parse manifest
$manifest = Read-WorkflowManifest -WorkflowDir $wfDir
$isIsolated = if ($null -ne $manifest.isolated) { [bool]$manifest.isolated } else { $true }

Write-DotbotBanner -Title "D O T B O T" -Subtitle "Run Workflow: $WorkflowName"

$activeRuns = Get-ActiveWorkflowRuns -BotRoot $BotDir
$startDecision = Test-CanStartRun `
    -NewRun @{ isolated = $isIsolated; workflow_name = $WorkflowName } `
    -ActiveRuns $activeRuns
if (-not $startDecision.ok) {
    Write-DotbotError $startDecision.message
    if ($startDecision.blocking_run_id) {
        Write-DotbotCommand "Blocking run: $($startDecision.blocking_run_id)"
    }
    exit 1
}

# --- Preflight checks ---
$envLocalPath = Join-Path $ProjectDir ".env.local"
if ($manifest.requires -and $manifest.requires.env_vars) {
    # Load .env.local
    $envValues = @{}
    if (Test-Path $envLocalPath) {
        Get-Content $envLocalPath | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.+)$') {
                $envValues[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
    }

    $missing = @()
    foreach ($ev in $manifest.requires.env_vars) {
        $varName = if ($ev.var) { $ev.var } elseif ($ev['var']) { $ev['var'] } else { continue }
        if (-not $envValues[$varName]) { $missing += $varName }
    }

    if ($missing.Count -gt 0) {
        Write-DotbotError "Missing required environment variables: $($missing -join ', ')"
        Write-DotbotWarning "Set them in .env.local"
        exit 1
    }
    Write-Success "Preflight: all required env vars present"
}

# --- Mint a fresh WorkflowRun ---
$tasks = @()
if ($manifest.tasks) { $tasks = @($manifest.tasks) }
if ($tasks.Count -eq 0) {
    Write-DotbotWarning "No tasks defined in workflow.yaml"
    exit 0
}

$runtimeStart = $null
$runtimeStartedHere = $false
$runtimeAlive = $false
if ($Watch) {
    Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1") -Force -DisableNameChecking
    $runtimeAlive = Test-RuntimeAlive -BotRoot $BotDir
    if (-not $runtimeAlive -and $NoAutoRuntime) {
        Write-DotbotError "The dotbot runtime is not running."
        Write-DotbotCommand "Run 'dotbot runtime-start' in another shell, or omit --no-auto-runtime."
        exit 1
    }
}

Write-Status "Minting WorkflowRun for '$WorkflowName'..."
$run = Initialize-WorkflowRun `
    -BotRoot         $BotDir `
    -WorkflowName    $WorkflowName `
    -StartedBy       'cli:workflow-run' `
    -Isolated        $isIsolated `
    -WorkflowPath    $wfDir `
    -WorkflowSource  $wfSource
Write-DotbotCommand "Run: $($run.run_id) → $($run.dir_name)"

Write-Status "Creating $($tasks.Count) task(s) under the run..."

foreach ($taskDef in $tasks) {
    $td = @{}
    if ($taskDef -is [PSCustomObject]) {
        foreach ($p in $taskDef.PSObject.Properties) { $td[$p.Name] = $p.Value }
    } elseif ($taskDef -is [System.Collections.IDictionary]) {
        $td = $taskDef
    }

    $result = New-WorkflowTask -Run $run -TaskDef $td
    Write-DotbotCommand "+ $($result.name) [$($result.id)]"
}

Write-Success "Created $($tasks.Count) task(s) for $WorkflowName"

# --- Spawn workflow process ---
$lpPath = Join-Path $DotbotBase "src/runtime/Scripts/Invoke-DotbotProcess.ps1"
Write-Status "Launching workflow process..."

if ($Watch) {
    if (-not $runtimeAlive) {
        Write-Status "Starting headless runtime..."
        $runtimeStart = Start-DotbotRuntime -BotRoot $BotDir
        $runtimeStartedHere = -not [bool]$runtimeStart.attached
        Write-Success ("Runtime ready at {0}" -f $runtimeStart.url)
    } else {
        Write-DotbotCommand "Using existing headless runtime."
    }
}

$wfArgs = @(
    "-Type", "task-runner",
    "-Continue",
    "-Workflow", $WorkflowName,
    "-RunId", $run.run_id,
    "-Description", "`"Run: $WorkflowName`""
)

try {
    $childProcess = Start-DotbotChildProcess -File $lpPath -FileArguments $wfArgs -WorkingDirectory $ProjectDir
} catch {
    if ($runtimeStartedHere -and $runtimeStart -and $runtimeStart.listener) {
        Stop-DotbotRuntime -BotRoot $BotDir -Listener $runtimeStart.listener -ErrorAction SilentlyContinue
    }
    throw
}

Write-BlankLine
Write-Success "Workflow '$WorkflowName' started."
if (-not $Watch) {
    Write-DotbotCommand "Use 'dotbot run $WorkflowName --watch' to run and monitor without opening the UI."
}
Write-BlankLine

if ($Watch) {
    $processesDir = Join-Path $BotDir ".control\processes"
    $proc = Wait-DotbotProcessFile -ProcessesDir $processesDir -ProcessPid $childProcess.Id -RunId $run.run_id
    if (-not $proc) {
        if ($runtimeStartedHere -and $runtimeStart -and $runtimeStart.listener) {
            Stop-DotbotRuntime -BotRoot $BotDir -Listener $runtimeStart.listener -ErrorAction SilentlyContinue
        }
        Write-DotbotError "The workflow runner did not register a process file."
        exit 1
    }

    try {
        $watchExit = Watch-DotbotWorkflowRun -ProcessesDir $processesDir -RunDir $run.run_dir -ProcessId $proc.id -PollMs $PollIntervalMs
    } finally {
        if ($runtimeStartedHere -and $runtimeStart -and $runtimeStart.listener) {
            Stop-DotbotRuntime -BotRoot $BotDir -Listener $runtimeStart.listener -ErrorAction SilentlyContinue
        }
    }
    exit $watchExit
}
