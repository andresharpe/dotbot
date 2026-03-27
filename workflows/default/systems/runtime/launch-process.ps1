<#
.SYNOPSIS
Unified process launcher replacing both loop scripts and ad-hoc Start-Job calls.

.DESCRIPTION
Every Claude invocation is a tracked process. Creates a process registry entry,
builds the appropriate prompt, invokes Claude, and manages the lifecycle.

.PARAMETER Type
Process type: analysis, execution, kickstart, planning, commit, task-creation

.PARAMETER TaskId
Optional: specific task ID (for analysis/execution types)

.PARAMETER Prompt
Optional: custom prompt text (for kickstart/planning/commit/task-creation)

.PARAMETER Continue
If set, continue to next task after completion (analysis/execution only)

.PARAMETER Model
Claude model to use (default: Opus)

.PARAMETER ShowDebug
Show raw JSON events

.PARAMETER ShowVerbose
Show detailed tool results

.PARAMETER MaxTasks
Max tasks to process with -Continue (0 = unlimited)

.PARAMETER Description
Human-readable description for UI display

.PARAMETER ProcessId
Optional: resume an existing process by ID (skips creation)

.PARAMETER NoWait
If set with -Continue, exit when no tasks available instead of waiting.
Used by kickstart pipeline to prevent workflow children from blocking phase progression.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('analysis', 'execution', 'workflow', 'kickstart', 'analyse', 'planning', 'commit', 'task-creation')]
    [string]$Type,

    [string]$TaskId,
    [string]$Prompt,
    [switch]$Continue,
    [string]$Model,
    [switch]$ShowDebug,
    [switch]$ShowVerbose,
    [int]$MaxTasks = 0,
    [string]$Description,
    [string]$ProcessId,
    [switch]$NeedsInterview,
    [switch]$AutoWorkflow,
    [switch]$NoWait,
    [string]$FromPhase,
    [string]$SkipPhases,  # comma-separated phase IDs to skip
    [string]$Workflow,    # filter task queue to this workflow name
    [ValidateRange(-1, 16)]
    [int]$Slot = -1       # concurrent slot index (-1 = single instance, 0..N = multi-slot)
)

Set-StrictMode -Version 1.0

# Validate TaskId format when provided
if ($TaskId -and $TaskId -notmatch '^[a-f0-9]{8}$') {
    Write-Warning "TaskId '$TaskId' does not match expected format (8-char hex). Proceeding anyway."
}

# Parse skip phases
$skipPhaseIds = if ($SkipPhases) { $SkipPhases -split ',' } else { @() }

# --- Configuration ---

# Determine phase for activity logging
$phaseMap = @{
    'analysis'      = 'analysis'
    'execution'     = 'execution'
    'workflow'      = 'workflow'
    'kickstart'     = 'execution'
    'analyse'       = 'execution'
    'planning'      = 'execution'
    'commit'        = 'execution'
    'task-creation' = 'execution'
}

$env:DOTBOT_CURRENT_PHASE = $phaseMap[$Type]

# Resolve paths
$botRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$controlDir = Join-Path $botRoot ".control"
$processesDir = Join-Path $controlDir "processes"
$projectRoot = Split-Path -Parent $botRoot
$global:DotbotProjectRoot = $projectRoot

# Ensure directories exist
if (-not (Test-Path $processesDir)) {
    New-Item -Path $processesDir -ItemType Directory -Force | Out-Null
}

# Import modules
Import-Module "$PSScriptRoot\ProviderCLI\ProviderCLI.psm1" -Force
Import-Module "$PSScriptRoot\ClaudeCLI\ClaudeCLI.psm1" -Force
Import-Module "$PSScriptRoot\modules\DotBotTheme.psm1" -Force
Import-Module "$PSScriptRoot\modules\InstanceId.psm1" -Force
$t = Get-DotBotTheme

# Set canonical version from version.json (available to all child scripts)
if (-not $env:DOTBOT_VERSION) {
    $versionFile = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'version.json'
    if (Test-Path $versionFile) {
        try { $env:DOTBOT_VERSION = (Get-Content $versionFile -Raw | ConvertFrom-Json).version } catch { Write-Verbose "Non-critical operation failed: $_" }
    }
}

. "$PSScriptRoot\modules\ui-rendering.ps1"
. "$PSScriptRoot\modules\prompt-builder.ps1"
. "$PSScriptRoot\modules\rate-limit-handler.ps1"

# Import task-based modules for analysis/execution/workflow types
if ($Type -in @('analysis', 'execution', 'workflow')) {
    Import-Module "$PSScriptRoot\..\mcp\modules\TaskIndexCache.psm1" -Force
    Import-Module "$PSScriptRoot\..\mcp\modules\SessionTracking.psm1" -Force
    . "$PSScriptRoot\modules\cleanup.ps1"
    . "$PSScriptRoot\modules\get-failure-reason.ps1"
    Import-Module "$PSScriptRoot\modules\WorktreeManager.psm1" -Force
    . "$PSScriptRoot\modules\test-task-completion.ps1"
    . "$PSScriptRoot\modules\create-problem-log.ps1"

    # MCP tool functions — load ALL tools dynamically (includes workflow-specific ones)
    $mcpToolsDir = Join-Path $PSScriptRoot "..\mcp\tools"
    Get-ChildItem -Path $mcpToolsDir -Directory | ForEach-Object {
        $toolScript = Join-Path $_.FullName "script.ps1"
        if (Test-Path $toolScript) { . $toolScript }
    }
}

# Load settings for model defaults
$settingsPath = Join-Path $botRoot "defaults\settings.default.json"
$settings = @{ execution = @{ model = 'Opus' }; analysis = @{ model = 'Opus' } }
if (Test-Path $settingsPath) {
    try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { Write-Verbose "Task operation failed: $_" }
}
# Workspace instance ID (stable per .bot workspace).
# For legacy projects missing this field, create and persist one.
$instanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
if (-not $instanceId) {
    $instanceId = ""
}

# Override model selections from UI settings (ui-settings.json)
$uiSettingsPath = Join-Path $botRoot ".control\ui-settings.json"
if (Test-Path $uiSettingsPath) {
    try {
        $uiSettings = Get-Content $uiSettingsPath -Raw | ConvertFrom-Json
        if ($uiSettings.analysisModel) { $settings.analysis.model = $uiSettings.analysisModel }
        if ($uiSettings.executionModel) { $settings.execution.model = $uiSettings.executionModel }
    } catch { Write-Verbose "Failed to parse data: $_" }
}

# Load provider config
$providerConfig = Get-ProviderConfig

# Resolve model (parameter > settings > provider default)
if (-not $Model) {
    $Model = switch ($Type) {
        { $_ -in @('analysis', 'kickstart') } { if ($settings.analysis?.model) { $settings.analysis.model } else { $providerConfig.default_model } }
        'workflow' { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
        default    { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
    }
}

try {
    $claudeModelName = Resolve-ProviderModelId -ModelAlias $Model
} catch {
    Write-Warning "Model '$Model' not valid for active provider. Falling back to '$($providerConfig.default_model)'."
    $claudeModelName = Resolve-ProviderModelId -ModelAlias $providerConfig.default_model
}
$env:CLAUDE_MODEL = $claudeModelName
$env:DOTBOT_MODEL = $claudeModelName

# --- Process Registry ---

function New-ProcessId {
    "proc-$([guid]::NewGuid().ToString().Substring(0,6))"
}

function Write-ProcessFile {
    param([string]$Id, [hashtable]$Data)
    $filePath = Join-Path $processesDir "$Id.json"
    $tempFile = "$filePath.tmp"

    $retryCount = if ($settings.operations.file_retry_count) { $settings.operations.file_retry_count } else { 3 }
    $retryBaseMs = if ($settings.operations.file_retry_base_ms) { $settings.operations.file_retry_base_ms } else { 50 }
    for ($r = 0; $r -lt $retryCount; $r++) {
        try {
            $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
            Move-Item -Path $tempFile -Destination $filePath -Force -ErrorAction Stop
            return
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            if ($r -lt ($retryCount - 1)) {
                Start-Sleep -Milliseconds ($retryBaseMs * ($r + 1))
            } else {
                Write-Diag "Write-ProcessFile FAILED for $Id after $retryCount retries: $_"
            }
        }
    }
}

function Write-ProcessActivity {
    param([string]$Id, [string]$ActivityType, [string]$Message)
    $logPath = Join-Path $processesDir "$Id.activity.jsonl"
    $event = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type = $ActivityType
        message = $Message
        task_id = $env:DOTBOT_CURRENT_TASK_ID
        phase = $env:DOTBOT_CURRENT_PHASE
    } | ConvertTo-Json -Compress

    $retryCount = if ($settings.operations.file_retry_count) { $settings.operations.file_retry_count } else { 3 }
    $retryBaseMs = if ($settings.operations.file_retry_base_ms) { $settings.operations.file_retry_base_ms } else { 50 }
    for ($r = 0; $r -lt $retryCount; $r++) {
        try {
            $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
            $sw.WriteLine($event)
            $sw.Close()
            $fs.Close()
            break
        } catch {
            if ($r -lt ($retryCount - 1)) { Start-Sleep -Milliseconds ($retryBaseMs * ($r + 1)) }
        }
    }

    # Also write to global activity.jsonl for oscilloscope backward compat.
    # Temporarily clear DOTBOT_PROCESS_ID to prevent Write-ActivityLog from
    # also writing to the process log (which we already wrote to above).
    $savedProcId = $env:DOTBOT_PROCESS_ID
    $env:DOTBOT_PROCESS_ID = $null
    try { Write-ActivityLog -Type $ActivityType -Message $Message } catch {
        Write-Diag "Write-ActivityLog FAILED: $_ | Type=$ActivityType Msg=$Message"
    }
    $env:DOTBOT_PROCESS_ID = $savedProcId
}

function Write-Diag {
    param([string]$Msg)
    if (-not $script:diagLogPath) { return }
    try {
        "$(Get-Date -Format 'o') [$PID] $Msg" | Add-Content -Path $script:diagLogPath -Encoding utf8NoBOM
    } catch { Write-Verbose "Logging operation failed: $_" }
}

function Test-ProcessStopSignal {
    param([string]$Id)
    $stopFile = Join-Path $processesDir "$Id.stop"
    Test-Path $stopFile
}

function Acquire-ProcessLock {
    <#
    .SYNOPSIS
    Atomically acquire a process lock using FileMode.CreateNew.
    Returns $true if lock acquired, $false if another live process holds it.
    Automatically cleans stale locks (dead PIDs).
    #>
    param([string]$LockType)
    $lockPath = Join-Path $controlDir "launch-$LockType.lock"

    # Check for existing lock and validate owner is alive
    if (Test-Path $lockPath) {
        $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
        if ($lockContent) {
            try {
                Get-Process -Id ([int]$lockContent.Trim()) -ErrorAction Stop | Out-Null
                return $false  # Lock held by a live process
            } catch {
                # Owner PID is dead — remove stale lock
                Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        }
    }

    # Atomic lock acquisition: CreateNew throws if file already exists
    try {
        $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($PID.ToString())
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            $fs.Close()
        }
        return $true
    } catch [System.IO.IOException] {
        # Another process beat us to it — verify that process is alive
        Start-Sleep -Milliseconds 50
        $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
        if ($lockContent) {
            try {
                Get-Process -Id ([int]$lockContent.Trim()) -ErrorAction Stop | Out-Null
                return $false  # Legitimate lock
            } catch {
                # Winner died immediately — clean up and retry once
                Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
                try {
                    $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PID.ToString())
                        $fs.Write($bytes, 0, $bytes.Length)
                    } finally {
                        $fs.Close()
                    }
                    return $true
                } catch {
                    return $false
                }
            }
        }
        return $false
    }
}

# Legacy aliases for backward compatibility
function Test-ProcessLock {
    param([string]$LockType)
    $lockPath = Join-Path $controlDir "launch-$LockType.lock"
    if (-not (Test-Path $lockPath)) { return $false }
    $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
    if (-not $lockContent) { return $false }
    try {
        Get-Process -Id ([int]$lockContent.Trim()) -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Set-ProcessLock {
    param([string]$LockType)
    $lockPath = Join-Path $controlDir "launch-$LockType.lock"
    $PID.ToString() | Set-Content $lockPath -NoNewline -Encoding utf8NoBOM
}

function Remove-ProcessLock {
    param([string]$LockType)
    $lockPath = Join-Path $controlDir "launch-$LockType.lock"
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

function Test-Preflight {
    $checks = @()
    $allPassed = $true

    # git on PATH
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $checks += "git: OK"
    } else {
        $checks += "git: MISSING - git not found on PATH"
        $allPassed = $false
    }

    # Provider CLI on PATH
    $providerExe = $providerConfig.executable
    $providerDisplay = $providerConfig.display_name
    $providerCmd = Get-Command $providerExe -ErrorAction SilentlyContinue
    if ($providerCmd) {
        $checks += "${providerExe}: OK"
    } else {
        $checks += "${providerExe}: MISSING - $providerDisplay CLI not found on PATH"
        $allPassed = $false
    }

    # .bot directory exists
    if (Test-Path $botRoot) {
        $checks += ".bot: OK"
    } else {
        $checks += ".bot: MISSING - $botRoot not found (run 'dotbot init' first)"
        $allPassed = $false
    }

    # powershell-yaml module
    $yamlMod = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
    if ($yamlMod) {
        $checks += "powershell-yaml: OK"
    } else {
        $checks += "powershell-yaml: MISSING - Install with: Install-Module powershell-yaml -Scope CurrentUser"
        $allPassed = $false
    }

    return @{ passed = $allPassed; checks = $checks }
}

function Add-YamlFrontMatter {
    param([string]$FilePath, [hashtable]$Metadata)
    $yaml = "---`n"
    foreach ($key in ($Metadata.Keys | Sort-Object)) {
        $yaml += "${key}: `"$($Metadata[$key])`"`n"
    }
    $yaml += "---`n`n"
    $existing = Get-Content $FilePath -Raw
    ($yaml + $existing) | Set-Content -Path $FilePath -Encoding utf8NoBOM -NoNewline
}

# Get-NextTodoTask: checks analysing/ for resumed tasks (answered questions), then todo/ for new tasks
function Get-NextTodoTask {
    param([switch]$Verbose)

    # First priority: check for analysing tasks that came back from needs-input
    $index = Get-TaskIndex
    $resumedTasks = @($index.Analysing.Values) | Sort-Object priority
    foreach ($candidate in $resumedTasks) {
        if ($candidate.file_path -and (Test-Path $candidate.file_path)) {
            try {
                $content = Get-Content -Path $candidate.file_path -Raw | ConvertFrom-Json
                $hasQR = $content.PSObject.Properties['questions_resolved'] -and $content.questions_resolved -and $content.questions_resolved.Count -gt 0
                $hasPQ = $content.PSObject.Properties['pending_question'] -and $content.pending_question
                if ($hasQR -and -not $hasPQ) {
                    Write-Status "Found resumed task (question answered): $($candidate.name)" -Type Info
                    $taskObj = @{
                        id = $content.id
                        name = $content.name
                        status = 'analysing'
                        priority = [int]$content.priority
                        effort = $content.effort
                        category = $content.category
                        type = $content.type
                        script_path = $content.script_path
                        mcp_tool = $content.mcp_tool
                        mcp_args = $content.mcp_args
                        skip_analysis = $content.skip_analysis
                        skip_worktree = $content.skip_worktree
                    }
                    if ($Verbose.IsPresent) {
                        $taskObj.description = $content.description
                        $taskObj.dependencies = $content.dependencies
                        $taskObj.acceptance_criteria = $content.acceptance_criteria
                        $taskObj.steps = $content.steps
                        $taskObj.applicable_agents = $content.applicable_agents
                        $taskObj.applicable_standards = $content.applicable_standards
                        $taskObj.file_path = $candidate.file_path
                        $taskObj.questions_resolved = if ($content.PSObject.Properties['questions_resolved']) { $content.questions_resolved } else { $null }
                        $taskObj.claude_session_id = if ($content.PSObject.Properties['claude_session_id']) { $content.claude_session_id } else { $null }
                        $taskObj.needs_interview = if ($content.PSObject.Properties['needs_interview']) { $content.needs_interview } else { $null }
                        $taskObj.working_dir = if ($content.PSObject.Properties['working_dir']) { $content.working_dir } else { $null }
                        $taskObj.external_repo = if ($content.PSObject.Properties['external_repo']) { $content.external_repo } else { $null }
                        $taskObj.research_prompt = if ($content.PSObject.Properties['research_prompt']) { $content.research_prompt } else { $null }
                    }
                    return @{
                        success = $true
                        task = $taskObj
                        message = "Resumed task (question answered): $($content.name)"
                    }
                }
            } catch {
                Write-Warning "Failed to read analysing task: $($candidate.file_path) - $_"
            }
        }
    }

    # Second priority: get next todo task
    $result = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false; verbose = $Verbose.IsPresent }
    if ($result.task -and $result.task.status -eq 'todo') {
        return $result
    }

    return @{
        success = $true
        task = $null
        message = "No tasks available for analysis."
    }
}

function Get-NextWorkflowTask {
    param([switch]$Verbose, [string]$WorkflowFilter)

    # First priority: check for analysing tasks that came back from needs-input
    $index = Get-TaskIndex
    $resumedTasks = @($index.Analysing.Values)
    if ($WorkflowFilter) {
        $resumedTasks = @($resumedTasks | Where-Object { $_.workflow -eq $WorkflowFilter })
    }
    $resumedTasks = $resumedTasks | Sort-Object priority
    foreach ($candidate in $resumedTasks) {
        if ($candidate.file_path -and (Test-Path $candidate.file_path)) {
            try {
                $content = Get-Content -Path $candidate.file_path -Raw | ConvertFrom-Json
                $hasQR = $content.PSObject.Properties['questions_resolved'] -and $content.questions_resolved -and $content.questions_resolved.Count -gt 0
                $hasPQ = $content.PSObject.Properties['pending_question'] -and $content.pending_question
                if ($hasQR -and -not $hasPQ) {
                    Write-Status "Found resumed task (question answered): $($candidate.name)" -Type Info
                    $taskObj = @{
                        id = $content.id
                        name = $content.name
                        status = 'analysing'
                        priority = [int]$content.priority
                        effort = $content.effort
                        category = $content.category
                        type = $content.type
                        script_path = $content.script_path
                        mcp_tool = $content.mcp_tool
                        mcp_args = $content.mcp_args
                        skip_analysis = $content.skip_analysis
                        skip_worktree = $content.skip_worktree
                        workflow = $content.workflow
                        model = $content.model
                    }
                    if ($Verbose.IsPresent) {
                        $taskObj.description = $content.description
                        $taskObj.dependencies = $content.dependencies
                        $taskObj.acceptance_criteria = $content.acceptance_criteria
                        $taskObj.steps = $content.steps
                        $taskObj.applicable_agents = $content.applicable_agents
                        $taskObj.applicable_standards = $content.applicable_standards
                        $taskObj.file_path = $candidate.file_path
                        $taskObj.questions_resolved = if ($content.PSObject.Properties['questions_resolved']) { $content.questions_resolved } else { $null }
                        $taskObj.claude_session_id = if ($content.PSObject.Properties['claude_session_id']) { $content.claude_session_id } else { $null }
                        $taskObj.needs_interview = if ($content.PSObject.Properties['needs_interview']) { $content.needs_interview } else { $null }
                        $taskObj.working_dir = if ($content.PSObject.Properties['working_dir']) { $content.working_dir } else { $null }
                        $taskObj.external_repo = if ($content.PSObject.Properties['external_repo']) { $content.external_repo } else { $null }
                        $taskObj.research_prompt = if ($content.PSObject.Properties['research_prompt']) { $content.research_prompt } else { $null }
                    }
                    return @{
                        success = $true
                        task = $taskObj
                        message = "Resumed task (question answered): $($content.name)"
                    }
                }
            } catch {
                Write-Warning "Failed to read analysing task: $($candidate.file_path) - $_"
            }
        }
    }

    # Second priority: prefer analysed tasks (ready for execution), then todo
    $wfFilterArgs = @{ prefer_analysed = $true; verbose = $Verbose.IsPresent }
    if ($WorkflowFilter) { $wfFilterArgs['workflow_filter'] = $WorkflowFilter }
    $result = Invoke-TaskGetNext -Arguments $wfFilterArgs
    return $result
}

# --- Crash Trap ---
# Catch unexpected termination and persist process state before exit
trap {
    if ($procId -and $processData -and $processData.status -in @('running', 'starting')) {
        $processData.status = 'stopped'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = "Unexpected termination: $($_.Exception.Message)"
        try { Write-ProcessFile -Id $procId -Data $processData } catch { Write-Verbose "Non-critical operation failed: $_" }
        try { Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process terminated unexpectedly: $($_.Exception.Message)" } catch { Write-Verbose "Failed to read process data: $_" }
    }
    try { Remove-ProcessLock -LockType $lockKey } catch { Write-Verbose "Logging operation failed: $_" }
}

# --- Preflight checks ---
$preflight = Test-Preflight
if (-not $preflight.passed) {
    Write-Warning "Preflight checks failed:"
    foreach ($check in $preflight.checks) {
        if ($check -match 'MISSING') { Write-Warning "  $check" }
    }
    exit 1
}

# --- Single-instance guard (slot-aware) ---
$lockKey = if ($Slot -ge 0) { "$Type-$Slot" } else { $Type }
if (-not (Acquire-ProcessLock -LockType $lockKey)) {
    $lockPath = Join-Path $controlDir "launch-$lockKey.lock"
    $existingPid = if (Test-Path $lockPath) { (Get-Content $lockPath -Raw -ErrorAction SilentlyContinue)?.Trim() } else { "unknown" }
    Write-Warning "Another $lockKey process is already running (PID $existingPid). Exiting."
    exit 1
}

# --- Initialize Process ---
$procId = if ($ProcessId) { $ProcessId } else { New-ProcessId }
$sessionId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
$claudeSessionId = New-ProviderSession

# Set process ID env var for dual-write activity logging in ClaudeCLI
$env:DOTBOT_PROCESS_ID = $procId

$processData = @{
    id              = $procId
    type            = $Type
    status          = 'starting'
    task_id         = $TaskId
    task_name       = $null
    continue        = [bool]$Continue
    no_wait         = [bool]$NoWait
    model           = $Model
    pid             = $PID
    session_id      = $sessionId
    claude_session_id = $claudeSessionId
    started_at      = (Get-Date).ToUniversalTime().ToString("o")
    last_heartbeat  = (Get-Date).ToUniversalTime().ToString("o")
    heartbeat_status = "Starting $Type process"
    heartbeat_next_action = $null
    last_whisper_index = 0
    completed_at    = $null
    failed_at       = $null
    tasks_completed = 0
    error           = $null
    workflow        = $null
    workflow_name   = if ($Workflow) { $Workflow } else { $null }
    description     = $Description
    phases          = @()
    skip_phases     = $skipPhaseIds
}

Write-ProcessFile -Id $procId -Data $processData

# Initialize diagnostic log
$script:diagLogPath = Join-Path $controlDir "diag-$procId.log"
Write-Diag "=== Process started: Type=$Type, ProcId=$procId, PID=$PID, Continue=$Continue, NoWait=$NoWait ==="
Write-Diag "BotRoot=$botRoot | ProcessesDir=$processesDir | ProjectRoot=$projectRoot"
$procFilePath = Join-Path $processesDir "$procId.json"
Write-Diag "Process file exists: $(Test-Path $procFilePath) at $procFilePath"

# Banner
Write-Card -Title "PROCESS: $($Type.ToUpper())" -Width 50 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines @(
    "$($t.Label)ID:$($t.Reset)    $($t.Cyan)$procId$($t.Reset)"
    "$($t.Label)Model:$($t.Reset) $($t.Purple)$Model$($t.Reset)"
    "$($t.Label)Type:$($t.Reset)  $($t.Amber)$Type$($t.Reset)"
)

Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId started ($Type)"
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Preflight OK: $($preflight.checks -join '; ')"


# --- Helper: Detect dependency deadlock from skipped tasks blocking the todo queue ---
function Test-DependencyDeadlock {
    param(
        [string]$ProcessId
    )
    $deadlock = Get-DeadlockedTasks
    if ($deadlock.BlockedCount -gt 0) {
        $blockers    = $deadlock.BlockerNames -join ', '
        $deadlockMsg = "Dependency deadlock: $($deadlock.BlockedCount) todo task(s) are blocked by skipped prerequisite(s) [$blockers]. Workflow cannot continue automatically — reset or re-implement the skipped tasks to unblock the queue."
        Write-Status $deadlockMsg -Type Error
        Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message $deadlockMsg
        return $true
    }
    return $false
}

# --- Helper: Interview loop (reusable for Phase 0 and interview-type phases) ---
function Invoke-InterviewLoop {
    param(
        [string]$ProcessId,
        [hashtable]$ProcessData,
        [string]$BotRoot,
        [string]$ProductDir,
        [string]$UserPrompt,
        [switch]$ShowDebugJson,
        [switch]$ShowVerboseOutput
    )

    $processData = $ProcessData

    # Load interview prompt template
    $interviewWorkflowPath = Join-Path $BotRoot "prompts\workflows\00-kickstart-interview.md"
    $interviewWorkflow = ""
    if (Test-Path $interviewWorkflowPath) {
        $interviewWorkflow = Get-Content $interviewWorkflowPath -Raw
    }

    # Check for briefing files
    $briefingDir = Join-Path $ProductDir "briefing"
    $interviewFileRefs = ""
    if (Test-Path $briefingDir) {
        $briefingFiles = Get-ChildItem -Path $briefingDir -File
        if ($briefingFiles.Count -gt 0) {
            $interviewFileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
            foreach ($bf in $briefingFiles) {
                $interviewFileRefs += "- $($bf.FullName)`n"
            }
        }
    }

    $interviewRound = 0
    $allQandA = @()
    $questionsPath = Join-Path $ProductDir "clarification-questions.json"
    $summaryPath = Join-Path $ProductDir "interview-summary.md"

    # Use Opus for interview quality
    $interviewModel = Resolve-ProviderModelId -ModelAlias 'Opus'

    do {
        $interviewRound++

        # Build previous Q&A context
        $previousContext = ""
        if ($allQandA.Count -gt 0) {
            $previousContext = "`n`n## Previous Interview Rounds`n"
            foreach ($round in $allQandA) {
                $previousContext += "`n### Round $($round.round)`n"
                foreach ($qa in $round.pairs) {
                    $previousContext += "**Q:** $($qa.question)`n**A:** $($qa.answer)`n`n"
                }
            }
        }

        # Clean up any previous round's files
        if (Test-Path $questionsPath) { Remove-Item $questionsPath -Force }
        if (Test-Path $summaryPath) { Remove-Item $summaryPath -Force }

        $interviewPrompt = @"
$interviewWorkflow

## User's Project Description

$UserPrompt
$interviewFileRefs
$previousContext

## Instructions

Review all context above. Decide whether to write clarification-questions.json (more questions needed) or interview-summary.md (all clear). Write exactly one file to .bot/workspace/product/.
"@

        Write-Status "Interview round $interviewRound..." -Type Process
        Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound"

        $interviewSessionId = New-ProviderSession
        $streamArgs = @{
            Prompt = $interviewPrompt
            Model = $interviewModel
            SessionId = $interviewSessionId
            PersistSession = $false
        }
        if ($ShowDebugJson) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerboseOutput) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ProviderStream @streamArgs

        # Check what Opus wrote
        if (Test-Path $summaryPath) {
            Write-Status "Interview complete — summary written" -Type Complete
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview complete after $interviewRound round(s)"

            # Add YAML front matter to interview summary
            $meta = @{
                generated_at = (Get-Date).ToUniversalTime().ToString("o")
                model = $interviewModel
                process_id = $ProcessId
                phase = "interview"
                generator = "dotbot-kickstart"
            }
            Add-YamlFrontMatter -FilePath $summaryPath -Metadata $meta

            break
        }

        if (Test-Path $questionsPath) {
            try {
                $questionsRaw = Get-Content $questionsPath -Raw
                $questionsData = $questionsRaw | ConvertFrom-Json
                $questions = $questionsData.questions
            } catch {
                Write-Status "Failed to parse questions JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            Write-Status "Round ${interviewRound}: $($questions.Count) question(s) — waiting for user" -Type Info

            # Set process to needs-input
            $processData.status = 'needs-input'
            $processData.pending_questions = $questionsData
            $processData.interview_round = $interviewRound
            $processData.heartbeat_status = "Waiting for interview answers (round $interviewRound)"
            Write-ProcessFile -Id $ProcessId -Data $processData
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Waiting for user answers (round $interviewRound, $($questions.Count) questions)"

            # Poll for answers file
            $answersPath = Join-Path $ProductDir "clarification-answers.json"
            if (Test-Path $answersPath) { Remove-Item $answersPath -Force }

            while (-not (Test-Path $answersPath)) {
                if (Test-ProcessStopSignal -Id $ProcessId) {
                    Write-Status "Stop signal received during interview" -Type Error
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    $processData.pending_questions = $null
                    Write-ProcessFile -Id $ProcessId -Data $processData
                    throw "Process stopped by user during interview"
                }
                Start-Sleep -Seconds 2
            }

            # Read answers
            try {
                $answersRaw = Get-Content $answersPath -Raw
                $answersData = $answersRaw | ConvertFrom-Json
            } catch {
                Write-Status "Failed to parse answers JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            # Check if user skipped
            if ($answersData.skipped -eq $true) {
                Write-Status "User skipped interview" -Type Info
                Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "User skipped interview at round $interviewRound"
                # Clean up
                Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
                Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
                break
            }

            # Accumulate Q&A for next round
            $allQandA += @{
                round = $interviewRound
                pairs = @($answersData.answers)
            }

            Write-Status "Answers received for round $interviewRound" -Type Success
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Received answers for round $interviewRound"

            # Clean up for next iteration
            Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
            Remove-Item $answersPath -Force -ErrorAction SilentlyContinue

            # Reset process status
            $processData.status = 'running'
            $processData.pending_questions = $null
            $processData.interview_round = $null
            $processData.heartbeat_status = "Processing interview answers"
            Write-ProcessFile -Id $ProcessId -Data $processData
        } else {
            # Neither file written — something went wrong, proceed without
            Write-Status "Interview round produced no output — proceeding" -Type Warn
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound produced no output — skipping"
            break
        }
    } while ($true)

    # Ensure status is running after interview
    $processData.status = 'running'
    $processData.pending_questions = $null
    $processData.interview_round = $null
    Write-ProcessFile -Id $ProcessId -Data $processData
}
# --- Task-based types: analysis/execution ---
if ($Type -in @('analysis', 'execution')) {
    # Initialize session for execution type
    if ($Type -eq 'execution') {
        $sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
        if ($sessionResult.success) {
            $sessionId = $sessionResult.session.session_id
        }
    }

    # Load prompt templates
    $templateFile = switch ($Type) {
        'analysis'  { Join-Path $botRoot "prompts\workflows\98-analyse-task.md" }
        'execution' { Join-Path $botRoot "prompts\workflows\99-autonomous-task.md" }
    }
    $promptTemplate = Get-Content $templateFile -Raw

    $processData.workflow = switch ($Type) {
        'analysis'  { "98-analyse-task.md" }
        'execution' { "99-autonomous-task.md" }
    }

    # Standards and product context (execution only)
    $standardsList = ""
    $productMission = ""
    $entityModel = ""
    if ($Type -eq 'execution') {
        $standardsDir = Join-Path $botRoot "prompts\standards\global"
        if (Test-Path $standardsDir) {
            $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
                ForEach-Object { ".bot/prompts/standards/global/$($_.Name)" }
            $standardsList = if ($standardsFiles) { "- " + ($standardsFiles -join "`n- ") } else { "No standards files found." }
        }
        $productDir = Join-Path $botRoot "workspace\product"
        $productMission = if (Test-Path (Join-Path $productDir "mission.md")) { "Read the product mission and context from: .bot/workspace/product/mission.md" } else { "No product mission file found." }
        $entityModel = if (Test-Path (Join-Path $productDir "entity-model.md")) { "Read the entity model design from: .bot/workspace/product/entity-model.md" } else { "No entity model file found." }
    }

    # Task reset for analysis and execution
    . "$PSScriptRoot\modules\task-reset.ps1"
    $tasksBaseDir = Join-Path $botRoot "workspace\tasks"

    # Recover orphaned analysing tasks (both types benefit from this)
    Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $processesDir | Out-Null

    if ($Type -eq 'execution') {
        Reset-InProgressTasks -TasksBaseDir $tasksBaseDir | Out-Null
        Reset-SkippedTasks -TasksBaseDir $tasksBaseDir | Out-Null
    }

    # Clean up orphan worktrees from previous runs
    Remove-OrphanWorktrees -ProjectRoot $projectRoot -BotRoot $botRoot

    # Initialize task index for analysis
    if ($Type -eq 'analysis') {
        Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    }

    $tasksProcessed = 0
    $maxRetriesPerTask = 2
    $consecutiveFailureThreshold = 3

    # Update process status to running
    $processData.status = 'running'
    Write-ProcessFile -Id $procId -Data $processData
    Write-Information "process_start: id=$procId type=$Type" -Tags @('dotbot', 'process', 'lifecycle')

    try {
        while ($true) {
            # Check max tasks
            if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
                Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
                break
            }

            # Check stop signal
            if (Test-ProcessStopSignal -Id $procId) {
                Write-Status "Stop signal received" -Type Error
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process stopped by user"
                break
            }

            # Get next task
            Write-Status "Fetching next task..." -Type Process
            if ($Type -eq 'analysis') {
                Reset-TaskIndex

                # Wait for any active execution worktrees to merge first
                $waitingLogged = $false
                while ($true) {
                    Initialize-WorktreeMap -BotRoot $botRoot
                    $map = Read-WorktreeMap
                    $hasActiveExecutionWt = $false

                    if ($map.Count -gt 0) {
                        $index = Get-TaskIndex
                        foreach ($taskId in @($map.Keys)) {
                            if ($index.InProgress.ContainsKey($taskId) -or
                                $index.Done.ContainsKey($taskId)) {
                                $entry = $map[$taskId]
                                if ($entry.worktree_path -and (Test-Path $entry.worktree_path)) {
                                    $hasActiveExecutionWt = $true
                                    break
                                }
                            }
                        }
                    }

                    if (-not $hasActiveExecutionWt) { break }

                    if (-not $waitingLogged) {
                        Write-Status "Waiting for execution merge before next analysis..." -Type Info
                        Write-ProcessActivity -Id $procId -ActivityType "text" `
                            -Message "Waiting for execution to merge before starting next analysis"
                        $processData.heartbeat_status = "Waiting for execution merge"
                        Write-ProcessFile -Id $procId -Data $processData
                        $waitingLogged = $true
                    }

                    Start-Sleep -Seconds 5
                    if (Test-ProcessStopSignal -Id $procId) { break }
                }

                # For analysis: check resumed tasks (answered questions) first, then todo
                $taskResult = Get-NextTodoTask -Verbose

                # Immediately claim task to prevent execution from picking it up
                if ($taskResult.task) {
                    # Auto-promote non-prompt tasks that skip analysis
                    $taskSkipAnalysis = $taskResult.task.skip_analysis
                    $taskTypeVal = if ($taskResult.task.type) { $taskResult.task.type } else { 'prompt' }
                    if ($taskSkipAnalysis -or $taskTypeVal -notin @('prompt', 'prompt_template')) {
                        Write-Status "Auto-promoting task (type=$taskTypeVal, skip_analysis): $($taskResult.task.name)" -Type Info
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-promoted $($taskResult.task.name) (type=$taskTypeVal)"
                        Invoke-TaskMarkAnalysing -Arguments @{ task_id = $taskResult.task.id } | Out-Null
                        Invoke-TaskMarkAnalysed -Arguments @{
                            task_id = $taskResult.task.id
                            analysis = @{
                                summary = "Auto-promoted: task type '$taskTypeVal' skips LLM analysis"
                                auto_promoted = $true
                            }
                        } | Out-Null
                        $tasksProcessed++
                        continue
                    }
                    Invoke-TaskMarkAnalysing -Arguments @{ task_id = $taskResult.task.id } | Out-Null
                }
            } else {
                # For execution: prefer analysed, then todo
                $taskResult = Invoke-TaskGetNext -Arguments @{ verbose = $true }
            }

            # Use specific task if provided
            if ($TaskId -and $tasksProcessed -eq 0) {
                # First iteration with specific TaskId - fetch that specific task
                # TaskId was provided, the task-get-next result may not match
                # We'll proceed with what we got from task-get-next, the prompt already has the task context
            }

            if (-not $taskResult.success) {
                Write-Status "Error fetching task: $($taskResult.message)" -Type Error
                break
            }

            if (-not $taskResult.task) {
                if ($Continue -and -not $NoWait) {
                    $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                    Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for new tasks..."

                    # Wait loop for new tasks
                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $procId) { break }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $procId -Data $processData
                        Reset-TaskIndex
                        if ($Type -eq 'analysis') {
                            $taskResult = Get-NextTodoTask -Verbose
                        } else {
                            $taskResult = Invoke-TaskGetNext -Arguments @{ verbose = $true }
                        }
                        if ($taskResult.task) { $foundTask = $true; break }

                        if (Test-DependencyDeadlock -ProcessId $procId) { break }
                    }
                    if (-not $foundTask) { break }
                } else {
                    Write-Status "No tasks available" -Type Info
                    break
                }
            }

            $task = $taskResult.task
            $processData.task_id = $task.id
            $processData.task_name = $task.name
            $processData.heartbeat_status = "Working on: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData

            $env:DOTBOT_CURRENT_TASK_ID = $task.id
            $taskTypeForHeader = if ($task.type) { $task.type } else { 'prompt' }
            Write-TaskHeader -TaskName $task.name -TaskType $taskTypeForHeader -Model $Model -ProcessId $procId
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Started task: $($task.name)"

            # Mark execution task immediately to prevent analysis from picking it up
            if ($Type -eq 'execution') {
                Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
                Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null
            }

            # --- Task type dispatch (script / mcp / task_gen bypass Claude) ---
            $taskTypeExec = if ($task.type) { $task.type } else { 'prompt' }
            if ($Type -eq 'execution' -and $taskTypeExec -notin @('prompt', 'prompt_template')) {
                $typeSuccess = $false
                $typeError = $null
                try {
                    switch ($taskTypeExec) {
                        'script' {
                            $resolvedScript = Join-Path $botRoot $task.script_path
                            Write-Status "Running script: $($task.script_path)" -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing script task: $($task.name)"
                            & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                            $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                        }
                        'mcp' {
                            $toolFuncParts = $task.mcp_tool -split '_'
                            $capitalParts = foreach ($p in $toolFuncParts) { $p.Substring(0,1).ToUpper() + $p.Substring(1) }
                            $toolFunc = 'Invoke-' + ($capitalParts -join '')
                            $toolArgs = if ($task.mcp_args) { $task.mcp_args } else { @{} }
                            Write-Status "Calling MCP tool: $($task.mcp_tool)" -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing MCP task: $($task.name)"
                            $mcpResult = & $toolFunc -Arguments $toolArgs
                            $typeSuccess = $true
                        }
                        'task_gen' {
                            $resolvedScript = Join-Path $botRoot $task.script_path
                            Write-Status "Running task generator: $($task.script_path)" -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Generating tasks: $($task.name)"
                            & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                            $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                            # Reset task index so newly created tasks are discovered
                            Reset-TaskIndex
                        }
                    }
                } catch {
                    $typeError = $_.Exception.Message
                    Write-Status "Task type execution failed: $typeError" -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
                }

                if ($typeSuccess) {
                    # Move task file directly to done/ (skip verification hooks —
                    # they are for Claude-executed code tasks, not script/mcp/task_gen)
                    try {
                        $doneDir = Join-Path $botRoot "workspace\tasks\done"
                        if (-not (Test-Path $doneDir)) { New-Item -Path $doneDir -ItemType Directory -Force | Out-Null }
                        $taskFile = Get-ChildItem (Join-Path $botRoot "workspace\tasks\in-progress") -Filter "*.json" -File |
                            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $task.id } |
                            Select-Object -First 1
                        if ($taskFile) {
                            $content = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                            $content.status = 'done'
                            $content.completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                            $content.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                            $content | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $doneDir $taskFile.Name) -Encoding UTF8
                            Remove-Item $taskFile.FullName -Force
                        }
                    } catch {
                        Write-Status "Failed to mark done: $($_.Exception.Message)" -Type Warn
                    }
                    Write-Status "Task completed: $($task.name)" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completed $taskTypeExec task: $($task.name)"
                    Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                    $tasksProcessed++
                } else {
                    Write-Status "Task failed: $($task.name)" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "$taskTypeExec execution failed: $typeError" } | Out-Null
                    } catch { Write-Verbose "Session operation failed: $_" }
                }
                continue
            }

            # --- Worktree setup ---
            $worktreePath = $null
            $branchName = $null
            if ($Type -eq 'execution') {
                # Execution: look up existing worktree or create new
                $wtInfo = Get-TaskWorktreeInfo -TaskId $task.id -BotRoot $botRoot
                if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
                    $worktreePath = $wtInfo.worktree_path
                    $branchName = $wtInfo.branch_name
                    Write-Status "Using worktree: $worktreePath" -Type Info
                } else {
                    # Guard: ensure main repo is on base branch before creating a new worktree (Fix: wrong-branch merge)
                    try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch {
                        Write-Status "Branch guard warning: $($_.Exception.Message)" -Type Warn
                    }
                    $wtResult = New-TaskWorktree -TaskId $task.id -TaskName $task.name `
                        -ProjectRoot $projectRoot -BotRoot $botRoot
                    if ($wtResult.success) {
                        $worktreePath = $wtResult.worktree_path
                        $branchName = $wtResult.branch_name
                        Write-Status "Worktree: $worktreePath" -Type Info
                    } else {
                        Write-Status "Worktree failed: $($wtResult.message)" -Type Warn
                    }
                }
            }
            # Analysis runs in $projectRoot (no worktree needed — it's read-only)

            # Generate new provider session ID per task
            $claudeSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $claudeSessionId
            $processData.claude_session_id = $claudeSessionId
            Write-ProcessFile -Id $procId -Data $processData

            # Build prompt
            if ($Type -eq 'execution') {
                $prompt = Build-TaskPrompt `
                    -PromptTemplate $promptTemplate `
                    -Task $task `
                    -SessionId $sessionId `
                    -ProductMission $productMission `
                    -EntityModel $entityModel `
                    -StandardsList $standardsList `
                    -InstanceId $instanceId

                $branchForPrompt = if ($branchName) { $branchName } else { "main" }
                $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

                $fullPrompt = @"
$prompt

## Process Context

- **Process ID:** $procId
- **Instance Type:** execution

Use the Process ID when calling `steering_heartbeat` (pass it as `process_id`).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call task_mark_done via MCP.
"@
            } else {
                # Analysis prompt
                $prompt = $promptTemplate
                $prompt = $prompt -replace '\{\{SESSION_ID\}\}', $sessionId
                $prompt = $prompt -replace '\{\{TASK_ID\}\}', $task.id
                $prompt = $prompt -replace '\{\{TASK_NAME\}\}', $task.name
                $prompt = $prompt -replace '\{\{TASK_CATEGORY\}\}', $task.category
                $prompt = $prompt -replace '\{\{TASK_PRIORITY\}\}', $task.priority
                $prompt = $prompt -replace '\{\{TASK_EFFORT\}\}', $task.effort
                $prompt = $prompt -replace '\{\{TASK_DESCRIPTION\}\}', $task.description
                $niValue = if ("$($task.needs_interview)" -eq 'true') { 'true' } else { 'false' }
                Write-Status "needs_interview raw=$($task.needs_interview) resolved=$niValue" -Type Info
                $prompt = $prompt -replace '\{\{NEEDS_INTERVIEW\}\}', $niValue
                $acceptanceCriteria = if ($task.acceptance_criteria) { ($task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n" } else { "No specific acceptance criteria defined." }
                $prompt = $prompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria
                $steps = if ($task.steps) { ($task.steps | ForEach-Object { "- $_" }) -join "`n" } else { "No specific steps defined." }
                $prompt = $prompt -replace '\{\{TASK_STEPS\}\}', $steps
                $splitThreshold = if ($settings.analysis.split_threshold_effort) { $settings.analysis.split_threshold_effort } else { 'XL' }
                $prompt = $prompt -replace '\{\{SPLIT_THRESHOLD_EFFORT\}\}', $splitThreshold

                $branchForPrompt = "main"
                $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

                # Build resolved questions context for resumed tasks
                $isResumedTask = $task.status -eq 'analysing'
                $resolvedQuestionsContext = ""
                $taskQR = if ($task.PSObject.Properties['questions_resolved']) { $task.questions_resolved } else { $null }
                if ($isResumedTask -and $taskQR) {
                    $resolvedQuestionsContext = "`n## Previously Resolved Questions`n`n"
                    $resolvedQuestionsContext += "This task was previously paused for human input. The following questions have been answered:`n`n"
                    foreach ($q in $taskQR) {
                        $resolvedQuestionsContext += "**Q:** $($q.question)`n"
                        $resolvedQuestionsContext += "**A:** $($q.answer)`n`n"
                    }
                    $resolvedQuestionsContext += "Use these answers to guide your analysis. The task is already in ``analysing`` status - do NOT call ``task_mark_analysing`` again.`n"
                }

                $fullPrompt = @"
$prompt
$resolvedQuestionsContext
## Process Context

- **Process ID:** $procId
- **Instance Type:** analysis

Use the Process ID when calling `steering_heartbeat` (pass it as `process_id`).

## Completion Goal

Analyse task $($task.id) completely. When analysis is finished:
- If all context is gathered: Call task_mark_analysed with the full analysis object
- If you need human input: Call task_mark_needs_input with a question or split_proposal
- If blocked by issues: Call task_mark_skipped with a reason

Do NOT implement the task. Your job is research and preparation only.
"@
            }

            # Invoke Claude with retries
            $attemptNumber = 0
            $taskSuccess = $false

            if ($worktreePath) { Push-Location $worktreePath }
            try {
            while ($attemptNumber -le $maxRetriesPerTask) {
                $attemptNumber++

                if ($attemptNumber -gt 1) {
                    Write-Status "Retry attempt $attemptNumber of $maxRetriesPerTask" -Type Warn
                }

                # Check stop signal before each attempt
                if (Test-ProcessStopSignal -Id $procId) {
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                    break
                }

                Write-Header "Claude Session"
                try {
                    $streamArgs = @{
                        Prompt = $fullPrompt
                        Model = $claudeModelName
                        SessionId = $claudeSessionId
                        PersistSession = $false
                    }
                    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                    Invoke-ProviderStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Kill any background processes Claude may have spawned in the worktree
                if ($worktreePath) {
                    $cleanedUp = Stop-WorktreeProcesses -WorktreePath $worktreePath
                    if ($cleanedUp -gt 0) {
                        Write-Diag "Cleaned up $cleanedUp orphan process(es) after $Type attempt"
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Cleaned up $cleanedUp background process(es) from worktree"
                    }
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                # Check rate limit
                $rateLimitMsg = Get-LastProviderRateLimitInfo
                if ($rateLimitMsg) {
                    Write-Status "Rate limit detected!" -Type Warn
                    Write-Information "rate_limit: process=$procId task=$($task.id) msg=$rateLimitMsg" -Tags @('dotbot', 'process', 'rate_limit')
                    $rateLimitInfo = Get-RateLimitResetTime -Message $rateLimitMsg
                    if ($rateLimitInfo) {
                        $processData.heartbeat_status = "Rate limited - waiting..."
                        Write-ProcessFile -Id $procId -Data $processData
                        Write-ProcessActivity -Id $procId -ActivityType "rate_limit" -Message $rateLimitMsg

                        # Simple wait - check stop signal periodically
                        $waitSeconds = $rateLimitInfo.wait_seconds
                        if (-not $waitSeconds -or $waitSeconds -lt 30) { $waitSeconds = 60 }
                        for ($w = 0; $w -lt $waitSeconds; $w++) {
                            Start-Sleep -Seconds 1
                            if (Test-ProcessStopSignal -Id $procId) { break }
                        }

                        $attemptNumber--  # Don't count rate limit as attempt
                        continue
                    }
                }

                # Check completion
                if ($Type -eq 'execution') {
                    $completionCheck = Test-TaskCompletion -TaskId $task.id
                    if ($completionCheck.completed) {
                        Write-Status "Task completed!" -Type Complete
                        Write-Information "task_state_change: $($task.id) -> done [execution]" -Tags @('dotbot', 'task', 'state')
                        Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                        $taskSuccess = $true
                        break
                    }
                } else {
                    # Analysis: check if task moved to analysed/needs-input/skipped
                    $taskDirs = @('analysed', 'needs-input', 'skipped', 'in-progress', 'done')
                    $taskFound = $false
                    foreach ($dir in $taskDirs) {
                        $checkDir = Join-Path $botRoot "workspace\tasks\$dir"
                        if (Test-Path $checkDir) {
                            $files = Get-ChildItem -Path $checkDir -Filter "*.json" -File
                            foreach ($f in $files) {
                                try {
                                    $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                                    if ($content.id -eq $task.id) {
                                        $taskFound = $true
                                        $taskSuccess = $true
                                        Write-Status "Analysis complete (status: $dir)" -Type Complete
                                        Write-Information "task_state_change: $($task.id) -> $dir [analysis]" -Tags @('dotbot', 'task', 'state')
                                        break
                                    }
                                } catch { Write-Verbose "Failed to parse data: $_" }
                            }
                            if ($taskFound) { break }
                        }
                    }
                    if ($taskSuccess) { break }
                }

                # Task not completed - handle failure
                if ($Type -eq 'execution') {
                    $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout "" -Stderr "" -TimedOut $false
                    if (-not $failureReason.recoverable) {
                        Write-Status "Non-recoverable failure - skipping" -Type Error
                        try {
                            Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "non-recoverable" } | Out-Null
                        } catch { Write-Verbose "Task operation failed: $_" }
                        break
                    }
                }

                if ($attemptNumber -ge $maxRetriesPerTask) {
                    Write-Status "Max retries exhausted" -Type Error
                    if ($Type -eq 'execution') {
                        try {
                            Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "max-retries" } | Out-Null
                        } catch { Write-Verbose "Task operation failed: $_" }
                    }
                    break
                }
            }
            } finally {
                # Final safety-net cleanup: kill any remaining worktree processes
                if ($worktreePath) {
                    Stop-WorktreeProcesses -WorktreePath $worktreePath | Out-Null
                    Pop-Location
                }
            }

            # Update process data
            $env:DOTBOT_CURRENT_TASK_ID = $null
            $env:CLAUDE_SESSION_ID = $null

            if ($taskSuccess) {
                # Post-completion: squash-merge task branch to main (execution only)
                if ($Type -eq 'execution' -and $worktreePath) {
                    Write-Status "Merging task branch to main..." -Type Process
                    $mergeResult = Complete-TaskWorktree -TaskId $task.id -ProjectRoot $projectRoot -BotRoot $botRoot
                    if ($mergeResult.success) {
                        Write-Status "Merged: $($mergeResult.message)" -Type Complete
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Squash-merged to main: $($task.name)"
                        if ($mergeResult.push_result.attempted) {
                            if ($mergeResult.push_result.success) {
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pushed to remote: $($task.name)"
                            } else {
                                Write-Status "Push failed: $($mergeResult.push_result.error)" -Type Warning
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Push failed after merge: $($mergeResult.push_result.error)"
                            }
                        }
                    } else {
                        Write-Status "Merge failed: $($mergeResult.message)" -Type Error
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Merge failed for $($task.name): $($mergeResult.message)"

                        # Escalate: move task from done/ to needs-input/ with conflict info
                        $doneDir = Join-Path $tasksBaseDir "done"
                        $needsInputDir = Join-Path $tasksBaseDir "needs-input"
                        $taskFile = Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
                            try {
                                $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
                                $c.id -eq $task.id
                            } catch { $false }
                        } | Select-Object -First 1

                        if ($taskFile) {
                            $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                            $taskContent.status = 'needs-input'
                            $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("o")

                            if (-not $taskContent.PSObject.Properties['pending_question']) {
                                $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
                            }
                            $taskContent.pending_question = @{
                                id             = "merge-conflict"
                                question       = "Merge conflict during squash-merge to main"
                                context        = "Conflict details: $($mergeResult.conflict_files -join '; '). Worktree preserved at: $worktreePath"
                                options        = @(
                                    @{ key = "A"; label = "Resolve manually and retry (recommended)"; rationale = "Inspect the worktree, resolve conflicts, then retry merge" }
                                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                                    @{ key = "C"; label = "Retry with fresh rebase"; rationale = "Reset and attempt rebase again" }
                                )
                                recommendation = "A"
                                asked_at       = (Get-Date).ToUniversalTime().ToString("o")
                            }

                            if (-not (Test-Path $needsInputDir)) {
                                New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
                            }
                            $newPath = Join-Path $needsInputDir $taskFile.Name
                            $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newPath -Encoding UTF8
                            Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue

                            Write-Status "Task moved to needs-input for manual conflict resolution" -Type Warn
                        }
                    }
                }

                $tasksProcessed++
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed: $($task.name)"

                # Clean up Claude session
                try { Remove-ProviderSession -SessionId $claudeSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-Verbose "Session operation failed: $_" }
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"

                # Clean up worktree for failed/skipped tasks to unblock analysis
                if ($Type -eq 'execution' -and $worktreePath) {
                    Write-Status "Cleaning up worktree for failed task..." -Type Info
                    try {
                        Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                        git -C $projectRoot worktree remove $worktreePath --force 2>$null
                        git -C $projectRoot branch -D $branchName 2>$null
                    } finally {
                        # Map removal always runs even if junction/worktree cleanup throws (Fix: inconsistent registry)
                        Initialize-WorktreeMap -BotRoot $botRoot
                        Invoke-WorktreeMapLocked -Action {
                            $cleanupMap = Read-WorktreeMap
                            $cleanupMap.Remove($task.id)
                            Write-WorktreeMap -Map $cleanupMap
                        }
                        # Re-assert base branch after failed-task cleanup (Fix: wrong-branch merge)
                        try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch { Write-Verbose "Task operation failed: $_" }
                    }
                }

                # Update session failure counters (execution only)
                if ($Type -eq 'execution') {
                    try {
                        $state = Invoke-SessionGetState -Arguments @{}
                        $newFailures = $state.state.consecutive_failures + 1
                        Invoke-SessionUpdate -Arguments @{
                            consecutive_failures = $newFailures
                            tasks_skipped = $state.state.tasks_skipped + 1
                        } | Out-Null

                        if ($newFailures -ge $consecutiveFailureThreshold) {
                            Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                            break
                        }
                    } catch { Write-Verbose "Task operation failed: $_" }
                }
            }

            # Continue to next task?
            if (-not $Continue) { break }

            # Clear task ID for next iteration
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null

            # Delay between tasks
            Write-Status "Waiting 3s before next task..." -Type Info
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }

            if (Test-ProcessStopSignal -Id $procId) {
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                break
            }
        }
    } finally {
        # Final cleanup
        if ($processData.status -eq 'running') {
            $processData.status = 'completed'
            $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status))"

        if ($Type -eq 'execution') {
            try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch { Write-Verbose "Logging operation failed: $_" }
        }
    }
}

# --- Workflow type: unified analyse-then-execute per task ---
elseif ($Type -eq 'workflow') {
    # Initialize session for execution phase tracking
    $sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
    if ($sessionResult.success) {
        $sessionId = $sessionResult.session.session_id
    }
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Workflow child started (session: $sessionId, PID: $PID)"

    # Load both prompt templates
    $analysisTemplateFile = Join-Path $botRoot "prompts\workflows\98-analyse-task.md"
    $executionTemplateFile = Join-Path $botRoot "prompts\workflows\99-autonomous-task.md"
    $analysisPromptTemplate = Get-Content $analysisTemplateFile -Raw
    $executionPromptTemplate = Get-Content $executionTemplateFile -Raw

    $processData.workflow = "workflow (analyse + execute)"

    # Standards and product context (for execution phase)
    $standardsList = ""
    $productMission = ""
    $entityModel = ""
    $standardsDir = Join-Path $botRoot "prompts\standards\global"
    if (Test-Path $standardsDir) {
        $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
            ForEach-Object { ".bot/prompts/standards/global/$($_.Name)" }
        $standardsList = if ($standardsFiles) { "- " + ($standardsFiles -join "`n- ") } else { "No standards files found." }
    }
    $productDir = Join-Path $botRoot "workspace\product"
    $productMission = if (Test-Path (Join-Path $productDir "mission.md")) { "Read the product mission and context from: .bot/workspace/product/mission.md" } else { "No product mission file found." }
    $entityModel = if (Test-Path (Join-Path $productDir "entity-model.md")) { "Read the entity model design from: .bot/workspace/product/entity-model.md" } else { "No entity model file found." }

    # Task reset
    . "$PSScriptRoot\modules\task-reset.ps1"
    $tasksBaseDir = Join-Path $botRoot "workspace\tasks"

    # Recover orphaned tasks
    Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $processesDir | Out-Null
    Reset-InProgressTasks -TasksBaseDir $tasksBaseDir | Out-Null
    Reset-SkippedTasks -TasksBaseDir $tasksBaseDir | Out-Null

    # Clean up orphan worktrees
    Remove-OrphanWorktrees -ProjectRoot $projectRoot -BotRoot $botRoot

    # Initialize task index
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

    # Log task index state for diagnostics
    $initIndex = Get-TaskIndex
    $todoCount = if ($initIndex.Todo) { $initIndex.Todo.Count } else { 0 }
    $analysedCount = if ($initIndex.Analysed) { $initIndex.Analysed.Count } else { 0 }
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task index loaded: $todoCount todo, $analysedCount analysed"
    
    # Pre-flight: warn if main repo has uncommitted non-.bot/ files.
    # These don't block execution (verification runs in the worktree) but can
    # complicate the squash-merge stash/pop if left unresolved.
    try {
        $mainDirtyStatus = git -C $projectRoot status --porcelain 2>$null
        $mainDirtyFiles  = @($mainDirtyStatus | Where-Object { $_ -notmatch '\.bot/' })
        if ($mainDirtyFiles.Count -gt 0) {
            $fileList = ($mainDirtyFiles | ForEach-Object { $_.Substring(3).Trim() }) -join ', '
            Write-Status "Pre-flight: Main repo has $($mainDirtyFiles.Count) uncommitted non-.bot/ file(s). Commit them to avoid squash-merge complications: $fileList" -Type Warn
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pre-flight warning: Main repo has $($mainDirtyFiles.Count) uncommitted file(s) outside .bot/ ($fileList). Consider committing before workflow."
        }
    } catch { Write-Verbose "Git operation failed: $_" }

    $tasksProcessed = 0
    $maxRetriesPerTask = 2
    $consecutiveFailureThreshold = 3

    # Ensure repo has at least one commit (required for worktrees)
    $hasCommits = git -C $projectRoot rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Creating initial commit (required for worktrees)..." -Type Process
        git -C $projectRoot add .bot/ 2>$null
        git -C $projectRoot commit -m "chore: initialize dotbot" --allow-empty 2>$null
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Created initial git commit (repo had no commits)"
    }

    # Update process status to running
    $processData.status = 'running'
    Write-ProcessFile -Id $procId -Data $processData

    $loopIteration = 0
    try {
        while ($true) {
            $loopIteration++
            Write-Diag "--- Loop iteration $loopIteration ---"

            # Check max tasks
            Write-Diag "MaxTasks check: tasksProcessed=$tasksProcessed, MaxTasks=$MaxTasks"
            if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
                Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
                Write-Diag "EXIT: MaxTasks reached"
                break
            }

            # Check stop signal
            if (Test-ProcessStopSignal -Id $procId) {
                Write-Status "Stop signal received" -Type Error
                Write-Diag "EXIT: Stop signal received"
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process stopped by user"
                break
            }

            # ===== Pick next task =====
            # Stagger task pulls: each slot waits a random prime-number of seconds.
            # Primes (5,7,11,13) minimize collision probability between slots.
            if ($Slot -gt 0) {
                $staggerOptions = @(5, 7, 11, 13)
                $staggerSec = $staggerOptions | Get-Random
                Write-Status "Slot ${Slot}: stagger wait ${staggerSec}s..." -Type Info
                for ($sw = 0; $sw -lt $staggerSec; $sw++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $procId) { break }
                }
            }

            Write-Status "Fetching next task..." -Type Process
            Reset-TaskIndex

            # Check resumed tasks, analysed tasks, then todo
            $taskResult = Get-NextWorkflowTask -Verbose -WorkflowFilter $Workflow

            Write-Diag "TaskPickup: success=$($taskResult.success) hasTask=$($null -ne $taskResult.task) msg=$($taskResult.message)"

            if (-not $taskResult.success) {
                Write-Status "Error fetching task: $($taskResult.message)" -Type Error
                Write-Diag "EXIT: Error fetching task: $($taskResult.message)"
                break
            }

            if (-not $taskResult.task) {
                if ($Continue -and -not $NoWait) {
                    $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                    Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                    Write-Diag "Entering wait loop (Continue=$Continue, NoWait=$NoWait): $waitReason"
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for new tasks..."

                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $procId) { break }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $procId -Data $processData
                        Reset-TaskIndex
                        $taskResult = Get-NextWorkflowTask -Verbose -WorkflowFilter $Workflow
                        if ($taskResult.task) { $foundTask = $true; break }

                        if (Test-DependencyDeadlock -ProcessId $procId) { break }
                    }
                    if (-not $foundTask) {
                        Write-Diag "EXIT: No task found after wait loop (foundTask=$foundTask)"
                        break
                    }
                } else {
                    Write-Status "No tasks available" -Type Info
                    Write-Diag "EXIT: No tasks and Continue not set"
                    break
                }
            }

            $task = $taskResult.task

            # --- Non-prompt task slot guard (before claim) ---
            # Script/mcp/task_gen tasks must only run on slot 0.
            # Check BEFORE claiming to avoid orphaning tasks in in-progress.
            $taskTypeCheck = if ($task.type) { $task.type } else { 'prompt' }
            if ($taskTypeCheck -eq 'prompt_template') { $taskTypeCheck = 'prompt' }
            if ($Slot -gt 0 -and $taskTypeCheck -notin @('prompt')) {
                Write-Status "Slot ${Slot}: skipping $taskTypeCheck task '$($task.name)' (slot 0 only)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Slot ${Slot}: waiting for prompt tasks (skipping $taskTypeCheck task)"
                Start-Sleep -Seconds 5
                continue
            }

            # --- Multi-slot claim guard ---
            # When running with -Slot (concurrent workflow processes), another slot may
            # have claimed this task between our Get-NextWorkflowTask and this point.
            # Only needed for prompt tasks — non-prompt tasks are guarded by the slot 0 check above.
            if ($Slot -ge 0 -and $taskTypeCheck -eq 'prompt') {
                $claimOk = $false
                for ($claimAttempt = 0; $claimAttempt -lt 5; $claimAttempt++) {
                    try {
                        $claimStatus = if ($task.status -eq 'analysed') { 'in-progress' } else { 'analysing' }
                        $claimResult = $null
                        if ($claimStatus -eq 'in-progress' -and $task.status -ne 'in-progress') {
                            $claimResult = Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id }
                        } elseif ($claimStatus -eq 'analysing' -and $task.status -notin @('analysing', 'analysed')) {
                            $claimResult = Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id }
                        }
                        # Detect if another slot already claimed this task
                        if ($claimResult -and $claimResult.already_completed) {
                            throw "Task already completed"
                        }
                        if ($claimResult -and -not $claimResult.old_status) {
                            # No old_status means task was already in the target state (claimed by another slot)
                            throw "Task already claimed"
                        }
                        $claimOk = $true
                        break
                    } catch {
                        Write-Diag "Slot ${Slot}: task $($task.id) claimed by another slot, retrying..."
                        Start-Sleep -Milliseconds 200
                        Reset-TaskIndex
                        $taskResult = Get-NextWorkflowTask -Verbose -WorkflowFilter $Workflow
                        if (-not $taskResult.task) { break }
                        $task = $taskResult.task
                    }
                }
                if (-not $claimOk) {
                    Write-Status "Slot ${Slot}: could not claim a task after $($claimAttempt + 1) attempts" -Type Warn
                    if ($Continue) { continue } else { break }
                }
            }

            $processData.task_id = $task.id
            $processData.task_name = $task.name
            $env:DOTBOT_CURRENT_TASK_ID = $task.id
            $taskTypeForHeader = if ($task.type) { $task.type } else { 'prompt' }
            Write-TaskHeader -TaskName $task.name -TaskType $taskTypeForHeader -Model $Model -ProcessId $procId
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Processing task: $($task.name) (id: $($task.id), status: $($task.status))"
            Write-Diag "Selected task: id=$($task.id) name=$($task.name) status=$($task.status)"

            # Skip analysis for already-analysed tasks — jump straight to execution
            if ($task.status -eq 'analysed') {
                Write-Status "Task already analysed — skipping to execution phase" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task already analysed, proceeding to execution: $($task.name)"
                # Jump to Phase 2 (execution) below — the analysis block is wrapped in a conditional
            }

            try {   # Per-task try/catch — catches failures in BOTH analysis and execution phases

            # --- Task type dispatch (script / mcp / task_gen bypass Claude entirely) ---
            $taskTypeVal = if ($task.type) { $task.type } else { 'prompt' }
            # prompt_template uses Claude but with a workflow-specific prompt file
            # — falls through to the normal analysis+execution path below
            if ($taskTypeVal -eq 'prompt_template' -and $task.prompt) {
                # Resolve prompt template from workflow dir or .bot/
                $promptBase = $botRoot
                if ($task.workflow) {
                    $wfPromptBase = Join-Path $botRoot "workflows\$($task.workflow)"
                    if (Test-Path $wfPromptBase) { $promptBase = $wfPromptBase }
                }
                $templatePath = Join-Path $promptBase $task.prompt
                if (Test-Path $templatePath) {
                    # Override the execution prompt template for this task
                    $executionPromptTemplate = Get-Content $templatePath -Raw
                    Write-Status "Using workflow prompt: $($task.prompt)" -Type Info
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Prompt template: $($task.prompt)"
                }
                # Fall through to normal analysis+execution below (treated as 'prompt')
                $taskTypeVal = 'prompt'
            }
            if ($taskTypeVal -notin @('prompt')) {
                Write-Status "Auto-dispatching $taskTypeVal task: $($task.name)" -Type Process
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-dispatch $taskTypeVal task: $($task.name)"

                # Mark in-progress
                if ($task.status -ne 'in-progress') {
                    Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
                }

                $typeSuccess = $false
                $typeError = $null
                # Resolve script base: workflow dir or .bot/
                $scriptBase = $botRoot
                if ($task.workflow) {
                    $wfScriptBase = Join-Path $botRoot "workflows\$($task.workflow)"
                    if (Test-Path $wfScriptBase) { $scriptBase = $wfScriptBase }
                }

                # Pre-flight: verify script exists before attempting execution
                if ($taskTypeVal -in @('script', 'task_gen') -and $task.script_path) {
                    $resolvedScript = Join-Path $scriptBase $task.script_path
                    if (-not (Test-Path $resolvedScript)) {
                        $typeError = "Script not found: $($task.script_path) (base: $scriptBase)"
                        Write-Status $typeError -Type Error
                        Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
                        try {
                            Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = $typeError } | Out-Null
                        } catch { Write-Verbose "Logging operation failed: $_" }
                        $TaskId = $null; $processData.task_id = $null; $processData.task_name = $null
                        Start-Sleep -Seconds 3
                        continue
                    }
                }

                try {
                    switch ($taskTypeVal) {
                        'script' {
                            $resolvedScript = Join-Path $scriptBase $task.script_path
                            Write-Status "Running script: $($task.script_path)" -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing script: $($task.script_path)"
                            & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                            $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                        }
                        'mcp' {
                            $toolFuncParts = $task.mcp_tool -split '_'
                            $capitalParts = foreach ($p in $toolFuncParts) { $p.Substring(0,1).ToUpper() + $p.Substring(1) }
                            $toolFunc = 'Invoke-' + ($capitalParts -join '')
                            $toolArgs = if ($task.mcp_args) { $task.mcp_args } else { @{} }
                            Write-Status "Calling MCP tool: $($task.mcp_tool)" -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing MCP tool: $($task.mcp_tool)"
                            $mcpResult = & $toolFunc -Arguments $toolArgs
                            $typeSuccess = $true
                        }
                        'task_gen' {
                            $resolvedScript = Join-Path $scriptBase $task.script_path
                            Write-Status "Running task generator: $($task.script_path)" -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Generating tasks: $($task.script_path)"
                            & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                            $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                            # Reset task index so newly created tasks are discovered
                            Reset-TaskIndex
                        }
                    }
                } catch {
                    $typeError = $_.Exception.Message
                    Write-Status "Task type execution failed: $typeError" -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
                }

                if ($typeSuccess) {
                    # Move task file directly to done/ (skip verification hooks —
                    # they are for Claude-executed code tasks, not script/mcp/task_gen)
                    try {
                        $doneDir = Join-Path $botRoot "workspace\tasks\done"
                        if (-not (Test-Path $doneDir)) { New-Item -Path $doneDir -ItemType Directory -Force | Out-Null }
                        $taskFile = Get-ChildItem (Join-Path $botRoot "workspace\tasks\in-progress") -Filter "*.json" -File |
                            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $task.id } |
                            Select-Object -First 1
                        if ($taskFile) {
                            $content = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                            $content.status = 'done'
                            $content.completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                            $content.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                            $content | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $doneDir $taskFile.Name) -Encoding UTF8
                            Remove-Item $taskFile.FullName -Force
                        }
                    } catch {
                        Write-Status "Failed to mark done: $($_.Exception.Message)" -Type Warn
                    }
                    Write-Status "Task completed: $($task.name)" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completed $taskTypeVal task: $($task.name)"
                    Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                    $tasksProcessed++
                } else {
                    Write-Status "Task failed: $($task.name)" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "$taskTypeVal execution failed: $typeError" } | Out-Null
                    } catch { Write-Verbose "Session operation failed: $_" }
                }

                # Continue to next task (skip analysis + execution phases)
                $TaskId = $null
                $processData.task_id = $null
                $processData.task_name = $null
                for ($i = 0; $i -lt 3; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $procId) { break }
                }
                continue
            }

            # ===== PHASE 1: Analysis (skipped if task already analysed) =====
            if ($task.status -ne 'analysed') {

            # Auto-promote prompt tasks that skip analysis (e.g. scoring tasks)
            # Mirrors the standalone analysis process behavior (line ~910)
            if ($task.skip_analysis -eq $true) {
                Write-Status "Auto-promoting task (skip_analysis): $($task.name)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-promoted $($task.name) (skip_analysis=true)"
                if ($task.status -ne 'analysing') {
                    Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id } | Out-Null
                }
                Invoke-TaskMarkAnalysed -Arguments @{
                    task_id = $task.id
                    analysis = @{
                        summary = "Auto-promoted: task has skip_analysis=true"
                        auto_promoted = $true
                    }
                } | Out-Null
                # Fall through to execution phase
            } else {

            Write-Diag "Entering analysis phase for task $($task.id)"
            $env:DOTBOT_CURRENT_PHASE = 'analysis'
            $processData.heartbeat_status = "Analysing: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analysis phase started: $($task.name)"

            # Claim task for analysis (unless already analysing from resumed question)
            if ($task.status -ne 'analysing') {
                Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id } | Out-Null
            }

            # Build analysis prompt
            $analysisPrompt = $analysisPromptTemplate
            $analysisPrompt = $analysisPrompt -replace '\{\{SESSION_ID\}\}', $sessionId
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_ID\}\}', $task.id
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_NAME\}\}', $task.name
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_CATEGORY\}\}', $task.category
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_PRIORITY\}\}', $task.priority
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_EFFORT\}\}', $task.effort
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_DESCRIPTION\}\}', $task.description
            $niValue = if ("$($task.needs_interview)" -eq 'true') { 'true' } else { 'false' }
            $analysisPrompt = $analysisPrompt -replace '\{\{NEEDS_INTERVIEW\}\}', $niValue
            $acceptanceCriteria = if ($task.acceptance_criteria) { ($task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n" } else { "No specific acceptance criteria defined." }
            $analysisPrompt = $analysisPrompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria
            $steps = if ($task.steps) { ($task.steps | ForEach-Object { "- $_" }) -join "`n" } else { "No specific steps defined." }
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_STEPS\}\}', $steps
            $splitThreshold = if ($settings.analysis.split_threshold_effort) { $settings.analysis.split_threshold_effort } else { 'XL' }
            $analysisPrompt = $analysisPrompt -replace '\{\{SPLIT_THRESHOLD_EFFORT\}\}', $splitThreshold
            $analysisPrompt = $analysisPrompt -replace '\{\{BRANCH_NAME\}\}', 'main'

            # Build resolved questions context for resumed tasks
            $isResumedTask = $task.status -eq 'analysing'
            $resolvedQuestionsContext = ""
            $taskQR = if ($task.PSObject.Properties['questions_resolved']) { $task.questions_resolved } else { $null }
            if ($isResumedTask -and $taskQR) {
                $resolvedQuestionsContext = "`n## Previously Resolved Questions`n`n"
                $resolvedQuestionsContext += "This task was previously paused for human input. The following questions have been answered:`n`n"
                foreach ($q in $taskQR) {
                    $resolvedQuestionsContext += "**Q:** $($q.question)`n"
                    $resolvedQuestionsContext += "**A:** $($q.answer)`n`n"
                }
                $resolvedQuestionsContext += "Use these answers to guide your analysis. The task is already in ``analysing`` status - do NOT call ``task_mark_analysing`` again.`n"
            }

            # Use task-level model override
            $analysisModel = if ($task.model) { $task.model }
                elseif ($settings.analysis?.model) { $settings.analysis.model }
                else { 'Opus' }
            $analysisModelName = Resolve-ProviderModelId -ModelAlias $analysisModel

            $fullAnalysisPrompt = @"
$analysisPrompt
$resolvedQuestionsContext
## Process Context

- **Process ID:** $procId
- **Instance Type:** workflow (analysis phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Analyse task $($task.id) completely. When analysis is finished:
- If all context is gathered: Call task_mark_analysed with the full analysis object
- If you need human input: Call task_mark_needs_input with a question or split_proposal
- If blocked by issues: Call task_mark_skipped with a reason

Do NOT implement the task. Your job is research and preparation only.
"@

            # Invoke provider for analysis
            $analysisSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $analysisSessionId
            $processData.claude_session_id = $analysisSessionId
            Write-ProcessFile -Id $procId -Data $processData

            $analysisSuccess = $false
            $analysisAttempt = 0

            while ($analysisAttempt -le $maxRetriesPerTask) {
                $analysisAttempt++
                if (Test-ProcessStopSignal -Id $procId) { break }

                Write-Header "Analysis Phase"
                try {
                    $streamArgs = @{
                        Prompt = $fullAnalysisPrompt
                        Model = $analysisModelName
                        SessionId = $analysisSessionId
                        PersistSession = $false
                    }
                    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                    Invoke-ProviderStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Analysis error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                # Handle rate limit
                $rateLimitMsg = Get-LastProviderRateLimitInfo
                if ($rateLimitMsg) {
                    $rateLimitInfo = Get-RateLimitResetTime -Message $rateLimitMsg
                    if ($rateLimitInfo) {
                        $processData.heartbeat_status = "Rate limited - waiting..."
                        Write-ProcessFile -Id $procId -Data $processData
                        Write-ProcessActivity -Id $procId -ActivityType "rate_limit" -Message $rateLimitMsg
                        $waitSeconds = $rateLimitInfo.wait_seconds
                        if (-not $waitSeconds -or $waitSeconds -lt 30) { $waitSeconds = 60 }
                        for ($w = 0; $w -lt $waitSeconds; $w++) {
                            Start-Sleep -Seconds 1
                            if (Test-ProcessStopSignal -Id $procId) { break }
                        }
                        $analysisAttempt--
                        continue
                    }
                }

                # Check if analysis completed (task moved to analysed/needs-input/skipped)
                $taskDirs = @('analysed', 'needs-input', 'skipped', 'in-progress', 'done')
                $taskFound = $false
                $analysisOutcome = $null
                foreach ($dir in $taskDirs) {
                    $checkDir = Join-Path $botRoot "workspace\tasks\$dir"
                    if (Test-Path $checkDir) {
                        $files = Get-ChildItem -Path $checkDir -Filter "*.json" -File
                        foreach ($f in $files) {
                            try {
                                $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                                if ($content.id -eq $task.id) {
                                    $taskFound = $true
                                    $analysisSuccess = $true
                                    $analysisOutcome = $dir
                                    Write-Status "Analysis complete (status: $dir)" -Type Complete
                                    break
                                }
                            } catch { Write-Verbose "Failed to parse data: $_" }
                        }
                        if ($taskFound) { break }
                    }
                }
                if ($analysisSuccess) { break }

                if ($analysisAttempt -ge $maxRetriesPerTask) {
                    Write-Status "Analysis max retries exhausted" -Type Error
                    break
                }
            }

            # Clean up analysis session
            try { Remove-ProviderSession -SessionId $analysisSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-Verbose "Session operation failed: $_" }

            Write-Diag "Analysis outcome: success=$analysisSuccess outcome=$analysisOutcome"

            if (-not $analysisSuccess) {
                Write-Diag "Analysis FAILED for task $($task.id)"
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analysis failed: $($task.name)"
                # Skip to next task
                if (-not $Continue) { break }
                $TaskId = $null
                $processData.task_id = $null
                $processData.task_name = $null
                for ($i = 0; $i -lt 3; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $procId) { break }
                }
                continue
            }

            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analysis complete: $($task.name) -> $analysisOutcome"

            # If analysis resulted in needs-input or skipped, don't proceed to execution
            # Note: 'done' and 'in-progress' are valid outcomes (task completed during analysis)
            if ($analysisOutcome -notin @('analysed', 'done', 'in-progress')) {
                Write-Diag "Task not ready for execution: outcome=$analysisOutcome"
                Write-Status "Task not ready for execution (status: $analysisOutcome) - moving to next task" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) needs input or was skipped - moving on"
                if (-not $Continue) { break }
                $TaskId = $null
                $processData.task_id = $null
                $processData.task_name = $null
                for ($i = 0; $i -lt 3; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $procId) { break }
                }
                continue
            }

            # If task already completed during analysis (e.g. scoring tasks that called
            # task_mark_done from the analysis phase), skip execution and count as done
            if ($analysisOutcome -in @('done', 'in-progress')) {
                Write-Diag "Task completed during analysis (outcome=$analysisOutcome) — skipping execution"
                Write-Status "Task completed during analysis" -Type Complete
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) completed during analysis (status: $analysisOutcome)"
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $tasksProcessed++
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $procId -Data $processData
                try { Remove-ProviderSession -SessionId $analysisSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-Verbose "Session operation failed: $_" }
                $TaskId = $null
                $processData.task_id = $null
                $processData.task_name = $null
                for ($i = 0; $i -lt 3; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $procId) { break }
                }
                continue
            }
            } # end: else (full LLM analysis)
            } # end: if ($task.status -ne 'analysed') — analysis phase

            # ===== PHASE 2: Execution =====
            Write-Diag "Entering execution phase for task $($task.id)"
            $env:DOTBOT_CURRENT_PHASE = 'execution'
            $processData.heartbeat_status = "Executing: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution phase started: $($task.name)"

            try {

            # Re-read task data (analysis may have enriched it)
            Reset-TaskIndex
            $freshTask = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $true; verbose = $true }
            Write-Diag "Execution TaskGetNext: hasTask=$($null -ne $freshTask.task) matchesId=$($freshTask.task.id -eq $task.id)"
            if ($freshTask.task -and $freshTask.task.id -eq $task.id) {
                $task = $freshTask.task
            }

            # Mark in-progress
            Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
            Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

            # Worktree setup — skip for research tasks, tasks with external repos, and tasks with skip_worktree flag
            $skipWorktree = ($task.category -eq 'research') -or $task.working_dir -or $task.external_repo -or ($task.skip_worktree -eq $true)
            Write-Diag "Worktree: skip=$skipWorktree category=$($task.category) skip_worktree=$($task.skip_worktree)"
            $worktreePath = $null
            $branchName = $null

            if ($skipWorktree) {
                Write-Status "Skipping worktree (category: $($task.category))" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping worktree for task: $($task.name) (research/external repo task)"
            } else {
                $wtInfo = Get-TaskWorktreeInfo -TaskId $task.id -BotRoot $botRoot
                if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
                    $worktreePath = $wtInfo.worktree_path
                    $branchName = $wtInfo.branch_name
                    Write-Status "Using worktree: $worktreePath" -Type Info
                } else {
                    # Guard: ensure main repo is on base branch before creating a new worktree (Fix: wrong-branch merge)
                    try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch {
                        Write-Status "Branch guard warning: $($_.Exception.Message)" -Type Warn
                    }
                    $wtResult = New-TaskWorktree -TaskId $task.id -TaskName $task.name `
                        -ProjectRoot $projectRoot -BotRoot $botRoot
                    if ($wtResult.success) {
                        $worktreePath = $wtResult.worktree_path
                        $branchName = $wtResult.branch_name
                        Write-Status "Worktree: $worktreePath" -Type Info
                    } else {
                        Write-Status "Worktree failed: $($wtResult.message)" -Type Warn
                    }
                }
            }

            # Use task-level model override > execution model from settings > default
            $executionModel = if ($task.model) { $task.model }
                elseif ($settings.execution?.model) { $settings.execution.model }
                else { 'Opus' }
            $executionModelName = Resolve-ProviderModelId -ModelAlias $executionModel

            # Build execution prompt
            $executionPrompt = Build-TaskPrompt `
                -PromptTemplate $executionPromptTemplate `
                -Task $task `
                -SessionId $sessionId `
                -ProductMission $productMission `
                -EntityModel $entityModel `
                -StandardsList $standardsList `
                -InstanceId $instanceId

            $branchForPrompt = if ($branchName) { $branchName } else { "main" }
            $executionPrompt = $executionPrompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

            $fullExecutionPrompt = @"
$executionPrompt

## Process Context

- **Process ID:** $procId
- **Instance Type:** workflow (execution phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call task_mark_done via MCP.
"@

            # Invoke provider for execution
            $executionSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $executionSessionId
            $processData.claude_session_id = $executionSessionId
            Write-ProcessFile -Id $procId -Data $processData

            $taskSuccess = $false
            $attemptNumber = 0

            if ($worktreePath) { Push-Location $worktreePath }
            try {
            while ($attemptNumber -le $maxRetriesPerTask) {
                $attemptNumber++
                if ($attemptNumber -gt 1) {
                    Write-Status "Retry attempt $attemptNumber of $maxRetriesPerTask" -Type Warn
                }
                if (Test-ProcessStopSignal -Id $procId) {
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                    break
                }

                Write-Header "Execution Phase"
                try {
                    $streamArgs = @{
                        Prompt = $fullExecutionPrompt
                        Model = $executionModelName
                        SessionId = $executionSessionId
                        PersistSession = $false
                    }
                    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                    Invoke-ProviderStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Execution error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Kill any background processes Claude may have spawned in the worktree
                # (e.g., dev servers started with pnpm dev &, npx next start &)
                if ($worktreePath) {
                    $cleanedUp = Stop-WorktreeProcesses -WorktreePath $worktreePath
                    if ($cleanedUp -gt 0) {
                        Write-Diag "Cleaned up $cleanedUp orphan process(es) after execution attempt"
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Cleaned up $cleanedUp background process(es) from worktree"
                    }
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                # Handle rate limit
                $rateLimitMsg = Get-LastProviderRateLimitInfo
                if ($rateLimitMsg) {
                    $rateLimitInfo = Get-RateLimitResetTime -Message $rateLimitMsg
                    if ($rateLimitInfo) {
                        $processData.heartbeat_status = "Rate limited - waiting..."
                        Write-ProcessFile -Id $procId -Data $processData
                        Write-ProcessActivity -Id $procId -ActivityType "rate_limit" -Message $rateLimitMsg
                        $waitSeconds = $rateLimitInfo.wait_seconds
                        if (-not $waitSeconds -or $waitSeconds -lt 30) { $waitSeconds = 60 }
                        for ($w = 0; $w -lt $waitSeconds; $w++) {
                            Start-Sleep -Seconds 1
                            if (Test-ProcessStopSignal -Id $procId) { break }
                        }
                        $attemptNumber--
                        continue
                    }
                }

                # Check completion
                $completionCheck = Test-TaskCompletion -TaskId $task.id
                Write-Diag "Completion check: completed=$($completionCheck.completed)"
                if ($completionCheck.completed) {
                    Write-Status "Task completed!" -Type Complete
                    Write-Information "task_state_change: $($task.id) -> done [execution]" -Tags @('dotbot', 'task', 'state')
                    Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                    $taskSuccess = $true
                    break
                }

                # Task not completed - log diagnostic to help distinguish failure modes:
                # (a) task_mark_done was called but verification blocked it  → task still in in-progress/
                # (b) task_mark_done was never called (agent forgot)          → task not in any terminal dir
                $inProgressDir = Join-Path $tasksBaseDir "in-progress"
                $stillInProgress = $false
                try {
                    $stillInProgress = $null -ne (
                        Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Where-Object {
                            try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $task.id } catch { $false }
                        } | Select-Object -First 1
                    )
                } catch { Write-Verbose "Failed to parse data: $_" }

                if ($stillInProgress) {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' still in in-progress/. Check activity log: if a 'task_mark_done blocked' entry exists, verification failed; otherwise task_mark_done was likely never called."
                } else {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' not found in in-progress/ or done/ (unexpected state)."
                }

                # Task not completed - handle failure
                $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout "" -Stderr "" -TimedOut $false
                if (-not $failureReason.recoverable) {
                    Write-Status "Non-recoverable failure - skipping" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "non-recoverable" } | Out-Null
                    } catch { Write-Verbose "Task operation failed: $_" }
                    break
                }

                if ($attemptNumber -ge $maxRetriesPerTask) {
                    Write-Status "Max retries exhausted" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "max-retries" } | Out-Null
                    } catch { Write-Verbose "Task operation failed: $_" }
                    break
                }
            }
            } finally {
                # Final safety-net cleanup: kill any remaining worktree processes
                if ($worktreePath) {
                    Stop-WorktreeProcesses -WorktreePath $worktreePath | Out-Null
                    Pop-Location
                }
            }

            # Clean up execution session
            try { Remove-ProviderSession -SessionId $executionSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-Verbose "Cleanup: failed to stop process: $_" }

            } catch {
                # Execution phase setup/run failed — log and recover the task
                Write-Diag "Execution EXCEPTION: $($_.Exception.Message)"
                Write-Status "Execution failed: $($_.Exception.Message)" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution failed for $($task.name): $($_.Exception.Message)"
                try {
                    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
                    $todoDir = Join-Path $tasksBaseDir "todo"
                    $taskFile = Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match $task.id.Substring(0,8) } | Select-Object -First 1
                    if ($taskFile) {
                        $taskData = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                        $taskData.status = 'todo'
                        $taskData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $todoDir $taskFile.Name) -Encoding UTF8
                        Remove-Item $taskFile.FullName -Force
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Recovered task $($task.name) back to todo"
                    }
                } catch { Write-Warning "Failed to recover task: $_" }
                $taskSuccess = $false
            }

            # Update process data
            $env:DOTBOT_CURRENT_TASK_ID = $null
            $env:CLAUDE_SESSION_ID = $null

            Write-Diag "Task result: success=$taskSuccess"

            if ($taskSuccess) {
                # Squash-merge task branch to main
                if ($worktreePath) {
                    Write-Status "Merging task branch to main..." -Type Process
                    $mergeResult = Complete-TaskWorktree -TaskId $task.id -ProjectRoot $projectRoot -BotRoot $botRoot
                    if ($mergeResult.success) {
                        Write-Status "Merged: $($mergeResult.message)" -Type Complete
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Squash-merged to main: $($task.name)"
                        if ($mergeResult.push_result.attempted) {
                            if ($mergeResult.push_result.success) {
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pushed to remote: $($task.name)"
                            } else {
                                Write-Status "Push failed: $($mergeResult.push_result.error)" -Type Warning
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Push failed after merge: $($mergeResult.push_result.error)"
                            }
                        }
                    } else {
                        Write-Status "Merge failed: $($mergeResult.message)" -Type Error
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Merge failed for $($task.name): $($mergeResult.message)"

                        # Escalate: move task from done/ to needs-input/ with conflict info
                        $doneDir = Join-Path $tasksBaseDir "done"
                        $needsInputDir = Join-Path $tasksBaseDir "needs-input"
                        $taskFile = Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
                            try {
                                $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
                                $c.id -eq $task.id
                            } catch { $false }
                        } | Select-Object -First 1

                        if ($taskFile) {
                            $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                            $taskContent.status = 'needs-input'
                            $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("o")

                            if (-not $taskContent.PSObject.Properties['pending_question']) {
                                $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
                            }
                            $taskContent.pending_question = @{
                                id             = "merge-conflict"
                                question       = "Merge conflict during squash-merge to main"
                                context        = "Conflict details: $($mergeResult.conflict_files -join '; '). Worktree preserved at: $worktreePath"
                                options        = @(
                                    @{ key = "A"; label = "Resolve manually and retry (recommended)"; rationale = "Inspect the worktree, resolve conflicts, then retry merge" }
                                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                                    @{ key = "C"; label = "Retry with fresh rebase"; rationale = "Reset and attempt rebase again" }
                                )
                                recommendation = "A"
                                asked_at       = (Get-Date).ToUniversalTime().ToString("o")
                            }

                            if (-not (Test-Path $needsInputDir)) {
                                New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
                            }
                            $newPath = Join-Path $needsInputDir $taskFile.Name
                            $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newPath -Encoding UTF8
                            Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue

                            Write-Status "Task moved to needs-input for manual conflict resolution" -Type Warn
                        }
                    }
                }

                $tasksProcessed++
                Write-Diag "Tasks processed: $tasksProcessed"
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed (analyse+execute): $($task.name)"
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"

                # Clean up worktree for failed/skipped tasks
                if ($worktreePath) {
                    Write-Status "Cleaning up worktree for failed task..." -Type Info
                    try {
                        Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                        git -C $projectRoot worktree remove $worktreePath --force 2>$null
                        git -C $projectRoot branch -D $branchName 2>$null
                    } finally {
                        # Map removal always runs even if junction/worktree cleanup throws (Fix: inconsistent registry)
                        Initialize-WorktreeMap -BotRoot $botRoot
                        Invoke-WorktreeMapLocked -Action {
                            $cleanupMap = Read-WorktreeMap
                            $cleanupMap.Remove($task.id)
                            Write-WorktreeMap -Map $cleanupMap
                        }
                        # Re-assert base branch after failed-task cleanup (Fix: wrong-branch merge)
                        try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch { Write-Verbose "Task operation failed: $_" }
                    }
                }

                # Update session failure counters
                try {
                    $state = Invoke-SessionGetState -Arguments @{}
                    $newFailures = $state.state.consecutive_failures + 1
                    Invoke-SessionUpdate -Arguments @{
                        consecutive_failures = $newFailures
                        tasks_skipped = $state.state.tasks_skipped + 1
                    } | Out-Null

                    Write-Diag "Consecutive failures: $newFailures (threshold=$consecutiveFailureThreshold)"
                    if ($newFailures -ge $consecutiveFailureThreshold) {
                        Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                        Write-Diag "EXIT: Consecutive failure threshold reached"
                        break
                    }
                } catch { Write-Verbose "Non-critical operation failed: $_" }
            }

            } catch {
                # Per-task error recovery — catches anything that escapes the inner try/catches
                Write-Diag "Per-task EXCEPTION: $($_.Exception.Message)"
                Write-Status "Task failed unexpectedly: $($_.Exception.Message)" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) failed: $($_.Exception.Message)"

                # Recover task: move from whatever state back to todo
                try {
                    foreach ($searchDir in @('analysing', 'in-progress')) {
                        $dir = Join-Path $tasksBaseDir $searchDir
                        $found = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match $task.id.Substring(0,8) } | Select-Object -First 1
                        if ($found) {
                            $taskData = Get-Content $found.FullName -Raw | ConvertFrom-Json
                            $taskData.status = 'todo'
                            $todoDir = Join-Path $tasksBaseDir "todo"
                            $taskData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $todoDir $found.Name) -Encoding UTF8
                            Remove-Item $found.FullName -Force
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Recovered task $($task.name) back to todo"
                            break
                        }
                    }
                } catch { Write-Warning "Failed to recover task: $_" }
            }

            # Continue to next task?
            Write-Diag "Continue check: Continue=$Continue"
            if (-not $Continue) {
                Write-Diag "EXIT: Continue not set"
                break
            }

            # Clear task ID for next iteration
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null

            # Delay between tasks
            Write-Status "Waiting 3s before next task..." -Type Info
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }

            if (Test-ProcessStopSignal -Id $procId) {
                Write-Diag "EXIT: Stop signal after task completion"
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                break
            }
        }
    } catch {
        # Process-level error handler — catches anything that escapes the per-task try/catch
        Write-Diag "PROCESS-LEVEL EXCEPTION: $($_.Exception.Message)"
        $processData.status = 'failed'
        $processData.error = $_.Exception.Message
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        Write-Information "process_failed: id=$procId error=$($_.Exception.Message)" -Tags @('dotbot', 'process', 'lifecycle')
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process failed: $($_.Exception.Message)"
        try { Write-Status "Process failed: $($_.Exception.Message)" -Type Error } catch { Write-Host "Process failed: $($_.Exception.Message)" }
    } finally {
        # Final cleanup
        if ($processData.status -eq 'running') {
            $processData.status = 'completed'
            $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status), tasks_completed: $tasksProcessed)"
        Write-Information "process_end: id=$procId status=$($processData.status) tasks_completed=$tasksProcessed" -Tags @('dotbot', 'process', 'lifecycle')
        Write-Diag "=== Process ending: status=$($processData.status) tasksProcessed=$tasksProcessed ==="

        try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch { Write-Verbose "Logging operation failed: $_" }
    }
}

# --- Kickstart type: three-phase product setup ---
elseif ($Type -eq 'kickstart') {
    if (-not $Description) { $Description = "Kickstart project setup" }

    $processData.status = 'running'
    $processData.workflow = "kickstart-pipeline"
    $processData.description = $Description
    $processData.heartbeat_status = $Description
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "$Description started"

    $productDir = Join-Path $botRoot "workspace\product"

    # Ensure repo has at least one commit (required for worktrees and phase commits)
    $hasCommits = git -C $projectRoot rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Creating initial commit..." -Type Process
        git -C $projectRoot add .bot/ 2>$null
        git -C $projectRoot commit -m "chore: initialize dotbot" --allow-empty 2>$null
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Created initial git commit (repo had no commits)"
    }

    try {
        # ===== Kickstart task pipeline (manifest-driven) =====
        # Load manifest helpers
        . (Join-Path $botRoot "systems\runtime\modules\workflow-manifest.ps1")

        $kickstartPhases = @()
        $activeWorkflowDir = $null
        $manifest = Get-ActiveWorkflowManifest -BotRoot $botRoot
        if ($manifest -and $manifest.tasks -and $manifest.tasks.Count -gt 0) {
            Ensure-ManifestTaskIds -Tasks $manifest.tasks
            $kickstartPhases = @($manifest.tasks)
            # Capture the workflow install dir so script phases can resolve workflow-scoped templates
            $wfInstallRoot = Join-Path $botRoot "workflows"
            $firstWf = Get-ChildItem $wfInstallRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($firstWf) { $activeWorkflowDir = $firstWf.FullName }
        }

        # Fallback to settings.kickstart.phases for legacy installs
        if ($kickstartPhases.Count -eq 0 -and $settings.kickstart -and $settings.kickstart.phases) {
            $kickstartPhases = @($settings.kickstart.phases)
        }

        if (-not $kickstartPhases -or $kickstartPhases.Count -eq 0) {
            throw "No workflow tasks found — ensure a workflow.yaml exists or settings.kickstart.phases is configured"
        }

        # ===== Build phase tracking array from config =====
        $hasInterviewPhase = $kickstartPhases | Where-Object { $_.type -eq 'interview' }
        if ($NeedsInterview -and -not $hasInterviewPhase) {
            # Prepend a synthetic interview phase for tracking
            $processData.phases = @(@{
                id = "interview"; name = "Interview"; type = "interview"
                status = "pending"; started_at = $null; completed_at = $null; error = $null
            })
        } else {
            $processData.phases = @()
        }
        # Append all config-driven phases
        $processData.phases += @($kickstartPhases | ForEach-Object {
            @{
                id = $_.id; name = $_.name
                type = if ($_.type) { $_.type } else { "llm" }
                status = "pending"; started_at = $null; completed_at = $null; error = $null
            }
        })
        Write-ProcessFile -Id $procId -Data $processData

        # ===== Validate FromPhase =====
        $fromPhaseActive = $false
        if ($FromPhase) {
            $validPhaseIds = @($processData.phases | ForEach-Object { $_.id })
            if ($FromPhase -notin $validPhaseIds) {
                Write-Status "Unknown phase '$FromPhase' — running all phases" -Type Warn
                $FromPhase = $null
            } else {
                $fromPhaseActive = $true
            }
        }

        # ===== Phase 0: Interview (backward compat for profiles without interview-type phase) =====
        if ($NeedsInterview -and -not $hasInterviewPhase) {
            $interviewPhaseIdx = @($processData.phases | ForEach-Object { $_.id }).IndexOf('interview')

            if ($fromPhaseActive -and $FromPhase -ne 'interview') {
                $processData.phases[$interviewPhaseIdx].status = 'skipped'
                $processData.phases[$interviewPhaseIdx].completed_at = 'prior-run'
                Write-ProcessFile -Id $procId -Data $processData
            } else {
                if ($fromPhaseActive) { $fromPhaseActive = $false }
                $processData.phases[$interviewPhaseIdx].status = 'running'
                $processData.phases[$interviewPhaseIdx].started_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                $processData.heartbeat_status = "Phase 0: Interviewing for requirements"
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase 0 — interviewing for requirements..."
                Write-Header "Phase 0: Interview"

                Invoke-InterviewLoop -ProcessId $procId -ProcessData $processData `
                    -BotRoot $botRoot -ProductDir $productDir -UserPrompt $Prompt `
                    -ShowDebugJson:$ShowDebug -ShowVerboseOutput:$ShowVerbose

                $processData.phases[$interviewPhaseIdx].status = 'completed'
                $processData.phases[$interviewPhaseIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
            }
        }

        # Build briefing context once (shared across LLM phases)
        $briefingDir = Join-Path $productDir "briefing"
        $fileRefs = ""
        if (Test-Path $briefingDir) {
            $briefingFiles = Get-ChildItem -Path $briefingDir -File
            if ($briefingFiles.Count -gt 0) {
                $fileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
                foreach ($bf in $briefingFiles) {
                    $fileRefs += "- $($bf.FullName)`n"
                }
            }
        }

        # Build interview context once (shared across LLM phases)
        $interviewContext = ""
        $interviewSummaryPath = Join-Path $productDir "interview-summary.md"
        if (Test-Path $interviewSummaryPath) {
            $interviewContext = @"

## Interview Summary

An interview-summary.md file exists in .bot/workspace/product/ containing the user's clarified requirements with both verbatim answers and expanded interpretation. **Read this file** and use it to guide your decisions — it reflects the user's confirmed preferences for platform, architecture, technology, domain model, and other key directions.
"@
        }

        $phaseNum = 1
        foreach ($phase in $kickstartPhases) {
            $phaseName = $phase.name
            $trackIdx = @($processData.phases | ForEach-Object { $_.id }).IndexOf($phase.id)

            # --- FromPhase skip logic ---
            if ($fromPhaseActive -and $phase.id -ne $FromPhase) {
                if ($trackIdx -ge 0) {
                    $processData.phases[$trackIdx].status = 'skipped'
                    $processData.phases[$trackIdx].completed_at = 'prior-run'
                    Write-ProcessFile -Id $procId -Data $processData
                }
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): before resume point"
                Write-Status "Skipping phase $phaseNum ($phaseName) — before resume point" -Type Info
                $phaseNum++; continue
            }
            if ($fromPhaseActive) { $fromPhaseActive = $false }

            # --- Condition check (gitignore-style path patterns) ---
            if ($phase.condition) {
                if (-not (Test-ManifestCondition -ProjectRoot $projectRoot -Condition $phase.condition)) {
                    if ($trackIdx -ge 0) {
                        $processData.phases[$trackIdx].status = 'skipped'
                        $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $procId -Data $processData
                    }
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): condition not met ($($phase.condition))"
                    Write-Status "Skipping phase $phaseNum ($phaseName) — condition not met" -Type Info
                    $phaseNum++; continue
                }
            }

            # --- User-requested skip ---
            if ($phase.id -in $skipPhaseIds) {
                if ($trackIdx -ge 0) {
                    $processData.phases[$trackIdx].status = 'skipped'
                    $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                }
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): user opted out"
                Write-Status "Skipping phase $phaseNum ($phaseName) — user opted out" -Type Info
                $phaseNum++; continue
            }

            # Determine phase type
            $phaseType = if ($phase.type) { $phase.type } else { "llm" }

            # Mark phase as running
            if ($trackIdx -ge 0) {
                $processData.phases[$trackIdx].status = 'running'
                $processData.phases[$trackIdx].started_at = (Get-Date).ToUniversalTime().ToString("o")
            }
            $processData.heartbeat_status = "Phase ${phaseNum}: $phaseName"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase $phaseNum — $($phaseName.ToLower())..."
            Write-Header "Phase ${phaseNum}: $phaseName"

            if ($phaseType -eq "barrier") {
                # --- Barrier phase: no-op, marks dependencies as resolved ---
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Barrier phase $phaseNum ($phaseName) complete"
                Write-Status "Barrier phase $phaseNum ($phaseName) — dependencies resolved" -Type Complete

            } elseif ($phaseType -eq "workflow") {
                # --- Workflow phase: launch concurrent worker slots ---
                $wfConcurrency = 1
                if ($settings.scoring -and $settings.scoring.max_concurrent_scores) {
                    $wfConcurrency = [int]$settings.scoring.max_concurrent_scores
                } elseif ($settings.execution -and $settings.execution.max_concurrent) {
                    $wfConcurrency = [int]$settings.execution.max_concurrent
                }
                if ($wfConcurrency -lt 1) { $wfConcurrency = 1 }

                $launchScript = Join-Path $botRoot "systems\runtime\launch-process.ps1"
                $wfFilter = if ($settings.profile) { $settings.profile } else { "" }

                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Launching $wfConcurrency workflow worker(s)$(if ($wfFilter) { " (workflow: $wfFilter)" })"
                Write-Status "Launching $wfConcurrency workflow worker(s) for phase $phaseNum ($phaseName)" -Type Process

                $slotLogDir = Join-Path $controlDir "slot-logs"
                if (-not (Test-Path $slotLogDir)) { New-Item -Path $slotLogDir -ItemType Directory -Force | Out-Null }

                $childProcs = @()
                for ($s = 0; $s -lt $wfConcurrency; $s++) {
                    $slotArgs = @(
                        "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", "`"$launchScript`"",
                        "-Type", "workflow",
                        "-Slot", "$s",
                        "-Continue",
                        "-NoWait",
                        "-Model", $Model
                    )
                    if ($wfFilter) { $slotArgs += @("-Workflow", $wfFilter) }

                    $stdoutLog = Join-Path $slotLogDir "slot-$s-stdout.log"
                    $stderrLog = Join-Path $slotLogDir "slot-$s-stderr.log"

                    $childProc = Start-Process -FilePath "pwsh.exe" `
                        -ArgumentList $slotArgs `
                        -WorkingDirectory $projectRoot `
                        -RedirectStandardOutput $stdoutLog `
                        -RedirectStandardError $stderrLog `
                        -PassThru

                    $childProcs += $childProc
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Workflow worker slot $s started (PID: $($childProc.Id))"
                    Write-Status "Slot $s started (PID: $($childProc.Id))" -Type Info
                }

                # Poll for completion, relaying heartbeats and checking stop signal
                while ($true) {
                    if (Test-ProcessStopSignal -Id $procId) {
                        Write-Status "Stop signal — terminating workflow workers" -Type Error
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Stop signal: killing $($childProcs.Count) worker(s)"
                        foreach ($cp in $childProcs) {
                            try { if (-not $cp.HasExited) { Stop-Process -Id $cp.Id -Force -ErrorAction SilentlyContinue } } catch { Write-Verbose "Cleanup: failed to stop process: $_" }
                        }
                        throw "Process stopped by user during workflow phase"
                    }

                    $wfRunning = @($childProcs | Where-Object { -not $_.HasExited })
                    if ($wfRunning.Count -eq 0) { break }

                    $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                    $processData.heartbeat_status = "Workflow: $($wfRunning.Count)/$wfConcurrency workers active"
                    Write-ProcessFile -Id $procId -Data $processData
                    Start-Sleep -Seconds 5
                }

                # Report results
                $wfSucceeded = @($childProcs | Where-Object { $_.ExitCode -eq 0 }).Count
                $wfFailed = $wfConcurrency - $wfSucceeded
                $wfMsg = "Workflow phase complete: $wfSucceeded/$wfConcurrency workers succeeded"
                if ($wfFailed -gt 0) { $wfMsg += " ($wfFailed failed)" }
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message $wfMsg
                Write-Status $wfMsg -Type $(if ($wfFailed -gt 0) { 'Warn' } else { 'Complete' })

            } elseif ($phaseType -eq "interview") {
                # --- Interview phase: run interview loop at this point in the pipeline ---
                if (-not $NeedsInterview) {
                    if ($trackIdx -ge 0) {
                        $processData.phases[$trackIdx].status = 'skipped'
                        $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $procId -Data $processData
                    }
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping interview phase $phaseNum ($phaseName): not requested"
                    Write-Status "Skipping interview phase (not requested)" -Type Info
                    $phaseNum++; continue
                }

                Invoke-InterviewLoop -ProcessId $procId -ProcessData $processData `
                    -BotRoot $botRoot -ProductDir $productDir -UserPrompt $Prompt `
                    -ShowDebugJson:$ShowDebug -ShowVerboseOutput:$ShowVerbose

            } elseif ($phase.script) {
                # --- Script-only phase (no LLM) ---
                # Resolve script path: if it starts with 'scripts/' resolve from $botRoot, otherwise from systems/runtime/
                $rawScript = $phase.script
                $scriptPath = if ($rawScript -match '^scripts[/\\]') {
                    Join-Path $botRoot $rawScript
                } else {
                    Join-Path $botRoot "systems\runtime\$rawScript"
                }
                $scriptInvokeArgs = @{ BotRoot = $botRoot; Model = $claudeModelName; ProcessId = $procId }
                if ($activeWorkflowDir) { $scriptInvokeArgs['WorkflowDir'] = $activeWorkflowDir }
                & $scriptPath @scriptInvokeArgs
            } else {
                # --- LLM phase ---

                # Pre-phase cleanup: remove leftover clarification files from previous phases
                $phaseQuestionsPath = Join-Path $productDir "clarification-questions.json"
                $phaseAnswersPath = Join-Path $productDir "clarification-answers.json"
                if (Test-Path $phaseQuestionsPath) { Remove-Item $phaseQuestionsPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path $phaseAnswersPath) { Remove-Item $phaseAnswersPath -Force -ErrorAction SilentlyContinue }

                $wfContent = ""
                $wfPath = Join-Path $botRoot "prompts\workflows\$($phase.workflow)"
                if (Test-Path $wfPath) { $wfContent = Get-Content $wfPath -Raw }

                $phasePrompt = @"
$wfContent

User's project description:
$Prompt
$fileRefs
$interviewContext

Instructions:
1. Read any briefing files listed above and any existing project files (README.md, etc.) for additional context
2. If an interview-summary.md file exists in .bot/workspace/product/, read it carefully — it contains clarified requirements from the user
3. Follow the workflow above to create the required outputs. Write files to .bot/workspace/product/
4. Do NOT create tasks or use task management tools unless the workflow explicitly instructs you to
5. Write comprehensive, well-structured content based on the user's description and any attached files
6. Make reasonable inferences where details are missing — the user can refine later

IMPORTANT: If creating mission.md, it MUST begin with ## Executive Summary as the first content after the title. This is required for the UI to detect that product planning is complete.
"@

                $claudeSessionId = New-ProviderSession
                $streamArgs = @{
                    Prompt = $phasePrompt
                    Model = $claudeModelName
                    SessionId = $claudeSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                Invoke-ProviderStream @streamArgs

                # --- Post-phase question detection (Generate → Ask → Adjust) ---
                if (Test-Path $phaseQuestionsPath) {
                    try {
                        $phaseQData = (Get-Content $phaseQuestionsPath -Raw) | ConvertFrom-Json
                    } catch {
                        Write-Status "Failed to parse phase questions JSON: $($_.Exception.Message)" -Type Warn
                        $phaseQData = $null
                    }

                    if ($phaseQData -and $phaseQData.questions -and $phaseQData.questions.Count -gt 0) {
                        Write-Status "Phase $phaseNum ($phaseName): $($phaseQData.questions.Count) question(s) — waiting for user" -Type Info
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum has $($phaseQData.questions.Count) clarification question(s)"

                        # 1. ASK — Set process to needs-input, poll for answers
                        $processData.status = 'needs-input'
                        $processData.pending_questions = $phaseQData
                        $processData.heartbeat_status = "Waiting for answers (phase ${phaseNum}: $phaseName)"
                        Write-ProcessFile -Id $procId -Data $processData

                        if (Test-Path $phaseAnswersPath) { Remove-Item $phaseAnswersPath -Force }

                        while (-not (Test-Path $phaseAnswersPath)) {
                            if (Test-ProcessStopSignal -Id $procId) {
                                Write-Status "Stop signal received waiting for phase answers" -Type Error
                                $processData.status = 'stopped'
                                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                                $processData.pending_questions = $null
                                Write-ProcessFile -Id $procId -Data $processData
                                throw "Process stopped by user during phase $phaseNum questions"
                            }
                            Start-Sleep -Seconds 2
                        }

                        # Read answers
                        try {
                            $phaseAnswersData = (Get-Content $phaseAnswersPath -Raw) | ConvertFrom-Json
                        } catch {
                            Write-Status "Failed to parse phase answers JSON: $($_.Exception.Message)" -Type Warn
                            $phaseAnswersData = $null
                        }

                        # Check if user skipped
                        if ($phaseAnswersData -and $phaseAnswersData.skipped -eq $true) {
                            Write-Status "User skipped phase $phaseNum questions" -Type Info
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "User skipped phase $phaseNum questions"
                        } elseif ($phaseAnswersData) {
                            Write-Status "Answers received for phase $phaseNum" -Type Success
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Received answers for phase $phaseNum"

                            # 2. RECORD — Append Q&A to interview-summary.md
                            $summaryPath = Join-Path $productDir "interview-summary.md"
                            $timestamp = (Get-Date).ToUniversalTime().ToString("o")
                            $qaSection = "`n`n### Phase ${phaseNum}: $phaseName`n"
                            $qaSection += "| # | Question | Answer (verbatim) | Interpretation | Timestamp |`n"
                            $qaSection += "|---|----------|--------------------|----------------|-----------|`n"

                            $qIdx = 0
                            foreach ($ans in $phaseAnswersData.answers) {
                                $qIdx++
                                $qText = ($ans.question -replace '\|', '\|' -replace "`n", ' ')
                                $aText = ($ans.answer -replace '\|', '\|' -replace "`n", ' ')
                                $qaSection += "| q$qIdx | $qText | $aText | _pending_ | $timestamp |`n"
                            }

                            if (Test-Path $summaryPath) {
                                # Append to existing file
                                $existingContent = Get-Content $summaryPath -Raw
                                if ($existingContent -notmatch '## Clarification Log') {
                                    $qaSection = "`n## Clarification Log`n" + $qaSection
                                }
                                Add-Content -Path $summaryPath -Value $qaSection -NoNewline
                            } else {
                                # Create new summary with clarification log
                                $newSummary = "# Interview Summary`n`n## Clarification Log`n" + $qaSection
                                Set-Content -Path $summaryPath -Value $newSummary -NoNewline
                            }

                            # 3. ADJUST — Run holistic artifact correction pass
                            $adjustPromptPath = Join-Path $botRoot "prompts\includes\adjust-after-answers.md"
                            if (Test-Path $adjustPromptPath) {
                                $adjustContent = Get-Content $adjustPromptPath -Raw

                                $adjustPrompt = @"
$adjustContent

## Context

- **Phase that generated questions**: Phase $phaseNum — $phaseName
- **User's project description**: $Prompt
$fileRefs
$interviewContext

Instructions:
1. Read .bot/workspace/product/interview-summary.md for the full Q&A history including the new answers
2. Read ALL existing product artifacts in .bot/workspace/product/
3. Assess the impact of the new information across all artifacts
4. Enrich/correct any affected artifacts
5. Fill in the Interpretation column for the new Q&A entries in interview-summary.md
"@

                                Write-Status "Running post-answer adjustment for phase $phaseNum..." -Type Process
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Adjusting artifacts based on phase $phaseNum answers"

                                $adjustSessionId = New-ProviderSession
                                $adjustArgs = @{
                                    Prompt = $adjustPrompt
                                    Model = $claudeModelName
                                    SessionId = $adjustSessionId
                                    PersistSession = $false
                                }
                                if ($ShowDebug) { $adjustArgs['ShowDebugJson'] = $true }
                                if ($ShowVerbose) { $adjustArgs['ShowVerbose'] = $true }

                                Invoke-ProviderStream @adjustArgs

                                Write-Status "Post-answer adjustment complete for phase $phaseNum" -Type Complete
                            } else {
                                Write-Status "Adjust prompt not found at $adjustPromptPath — skipping adjustment" -Type Warn
                            }
                        }

                        # 4. CLEANUP — Remove JSON files, reset process status
                        Remove-Item $phaseQuestionsPath -Force -ErrorAction SilentlyContinue
                        Remove-Item $phaseAnswersPath -Force -ErrorAction SilentlyContinue
                        $processData.status = 'running'
                        $processData.pending_questions = $null
                        $processData.heartbeat_status = "Running phase $phaseNum"
                        Write-ProcessFile -Id $procId -Data $processData
                    }
                }
            }

            # --- Validation (skip for barrier/interview phase types) ---
            if ($phaseType -notin @("barrier", "interview")) {
                # Support both manifest-style 'outputs' and legacy 'required_outputs'
                $validationOutputs = if ($phase.outputs) { $phase.outputs } else { $phase.required_outputs }
                $validationOutputsDir = if ($phase.outputs_dir) { $phase.outputs_dir } else { $phase.required_outputs_dir }
                if ($validationOutputs) {
                    foreach ($f in $validationOutputs) {
                        if (-not (Test-Path (Join-Path $productDir $f))) {
                            throw "Phase $phaseNum ($phaseName) failed: $f was not created"
                        }
                    }
                } elseif ($validationOutputsDir) {
                    $dirPath = Join-Path $botRoot "workspace\$validationOutputsDir"
                    $minCount = if ($phase.min_output_count) { [int]$phase.min_output_count } else { 1 }
                    $fileCount = if (Test-Path $dirPath) {
                        @(Get-ChildItem $dirPath -File | Where-Object { $_.Name -notmatch '^[._]' }).Count
                    } else { 0 }
                    if ($fileCount -lt $minCount) {
                        throw "Phase $phaseNum ($phaseName) failed: expected at least $minCount file(s) in $validationOutputsDir, found $fileCount"
                    }
                }
            }

            # --- Front matter ---
            if ($phase.front_matter_docs) {
                $phaseMeta = @{
                    generated_at = (Get-Date).ToUniversalTime().ToString("o")
                    model = $claudeModelName
                    process_id = $procId
                    phase = "phase-$phaseNum-$($phase.id)"
                    generator = "dotbot-kickstart"
                }
                foreach ($docName in $phase.front_matter_docs) {
                    $docPath = Join-Path $productDir $docName
                    if (Test-Path $docPath) {
                        Add-YamlFrontMatter -FilePath $docPath -Metadata $phaseMeta
                    }
                }
            }

            # --- Post-script ---
            if ($phase.post_script) {
                $rawPostScript = $phase.post_script
                $postPath = if ($rawPostScript -match '^scripts[/\\]') {
                    Join-Path $botRoot $rawPostScript
                } else {
                    Join-Path $botRoot "systems\runtime\$rawPostScript"
                }
                & $postPath -BotRoot $botRoot -ProductDir $productDir -Settings $settings -Model $claudeModelName -ProcessId $procId
            }

            # --- Git checkpoint (supports manifest-style commit object and legacy commit_paths/commit_message) ---
            $commitPaths = if ($phase.commit -and $phase.commit.paths) { $phase.commit.paths } else { $phase.commit_paths }
            $commitMsg = if ($phase.commit -and $phase.commit.message) { $phase.commit.message }
                         elseif ($phase.commit_message) { $phase.commit_message }
                         else { "chore(kickstart): phase $phaseNum — $($phaseName.ToLower())" }
            if ($commitPaths) {
                Write-Status "Committing phase $phaseNum artifacts..." -Type Info
                foreach ($cp in $commitPaths) {
                    git -C $projectRoot add ".bot/$cp" 2>$null
                }
                git -C $projectRoot commit --quiet -m $commitMsg 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum checkpoint committed"
                } else {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum checkpoint: nothing to commit"
                }
            }

            # Mark phase as completed
            if ($trackIdx -ge 0) {
                $processData.phases[$trackIdx].status = 'completed'
                $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
            }

            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum complete — $($phaseName.ToLower())"
            $phaseNum++
        }

        # Done
        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.heartbeat_status = "Completed: $Description"
    } catch {
        # Mark the current phase as failed if we have a tracking index
        if ($trackIdx -ge 0 -and $processData.phases[$trackIdx].status -eq 'running') {
            $processData.phases[$trackIdx].status = 'failed'
            $processData.phases[$trackIdx].error = $_.Exception.Message
        }
        $processData.status = 'failed'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = $_.Exception.Message
        $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
        Write-Status "Process failed: $($_.Exception.Message)" -Type Error
        # C8: Log the error details to activity JSONL so failures aren't silent
        Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Phase failure: $($_.Exception.Message)"
    }

    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status))"
}

# --- Prompt-based types: planning, commit, task-creation ---
elseif ($Type -in @('planning', 'commit', 'task-creation')) {
    # Determine workflow template
    $workflowFile = switch ($Type) {
        'planning'      { Join-Path $botRoot "prompts\workflows\03-plan-roadmap.md" }
        'commit'        { Join-Path $botRoot "prompts\workflows\90-commit-and-push.md" }
        'task-creation' { Join-Path $botRoot "prompts\workflows\91-new-tasks.md" }
    }

    $processData.workflow = switch ($Type) {
        'planning'      { "03-plan-roadmap.md" }
        'commit'        { "90-commit-and-push.md" }
        'task-creation' { "91-new-tasks.md" }
    }

    # Build prompt
    $systemPrompt = ""
    if (Test-Path $workflowFile) {
        $systemPrompt = Get-Content $workflowFile -Raw
    }

    # For prompt-based types, append the custom prompt
    if ($Prompt) {
        $fullPrompt = @"
$systemPrompt

## Additional Context

$Prompt
"@
    } else {
        $fullPrompt = $systemPrompt
    }

    if (-not $Description) {
        $Description = switch ($Type) {
            'planning'      { "Plan roadmap" }
            'commit'        { "Commit and push changes" }
            'task-creation' { "Create new tasks" }
        }
    }

    $processData.status = 'running'
    $processData.description = $Description
    $processData.heartbeat_status = $Description
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "$Description started"

    try {
        $streamArgs = @{
            Prompt = $fullPrompt
            Model = $claudeModelName
            SessionId = $claudeSessionId
            PersistSession = $false
        }
        if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ProviderStream @streamArgs

        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.heartbeat_status = "Completed: $Description"
    } catch {
        $processData.status = 'failed'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = $_.Exception.Message
        $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
        Write-Status "Process failed: $($_.Exception.Message)" -Type Error
    }

    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status))"
}

# Cleanup env vars
Remove-ProcessLock -LockType $lockKey
$env:DOTBOT_PROCESS_ID = $null
$env:DOTBOT_CURRENT_TASK_ID = $null
$env:DOTBOT_CURRENT_PHASE = $null

# Output process ID for caller to use
Write-Host ""
try { Write-Status "Process $procId finished with status: $($processData.status)" -Type Info } catch { Write-Host "Process $procId finished with status: $($processData.status)" }

# 5-second countdown before window closes
Write-Host ""
for ($i = 5; $i -ge 1; $i--) {
    Write-Host "`r  Window closing in ${i}s..." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host ""
