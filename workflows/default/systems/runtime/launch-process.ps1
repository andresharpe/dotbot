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
    [ValidateSet('analysis', 'execution', 'task-runner', 'kickstart', 'analyse', 'planning', 'commit', 'task-creation')]
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
    'task-runner'   = 'task-runner'
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
if ($Type -in @('analysis', 'execution', 'task-runner')) {
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
$settingsPath = Join-Path $botRoot "settings\settings.default.json"
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
        'task-runner' { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
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

# --- Process Registry (module) ---
Import-Module "$PSScriptRoot\modules\ProcessRegistry.psm1" -Force
Initialize-ProcessRegistry `
    -ProcessesDir $processesDir `
    -ControlDir $controlDir `
    -Settings $settings `
    -ProviderConfig $providerConfig `
    -BotRoot $botRoot

# --- Interview Loop (dot-sourced for kickstart) ---
. "$PSScriptRoot\modules\InterviewLoop.ps1"

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

# Initialize diagnostic log (update module with diag path now that procId is known)
$script:diagLogPath = Join-Path $controlDir "diag-$procId.log"
Initialize-ProcessRegistry `
    -ProcessesDir $processesDir `
    -ControlDir $controlDir `
    -DiagLogPath $script:diagLogPath `
    -Settings $settings `
    -ProviderConfig $providerConfig `
    -BotRoot $botRoot
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
        'analysis'  { Join-Path $botRoot "recipes\prompts\98-analyse-task.md" }
        'execution' { Join-Path $botRoot "recipes\prompts\99-autonomous-task.md" }
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
        $standardsDir = Join-Path $botRoot "recipes\standards\global"
        if (Test-Path $standardsDir) {
            $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
                ForEach-Object { ".bot/recipes/standards/global/$($_.Name)" }
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

# --- Task Runner type: unified analyse-then-execute per task ---
elseif ($Type -eq 'task-runner') {
    # Initialize session for execution phase tracking
    $sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
    if ($sessionResult.success) {
        $sessionId = $sessionResult.session.session_id
    }
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Workflow child started (session: $sessionId, PID: $PID)"

    # Load both prompt templates
    $analysisTemplateFile = Join-Path $botRoot "recipes\prompts\98-analyse-task.md"
    $executionTemplateFile = Join-Path $botRoot "recipes\prompts\99-autonomous-task.md"
    $analysisPromptTemplate = Get-Content $analysisTemplateFile -Raw
    $executionPromptTemplate = Get-Content $executionTemplateFile -Raw

    $processData.workflow = "workflow (analyse + execute)"

    # Standards and product context (for execution phase)
    $standardsList = ""
    $productMission = ""
    $entityModel = ""
    $standardsDir = Join-Path $botRoot "recipes\standards\global"
    if (Test-Path $standardsDir) {
        $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
            ForEach-Object { ".bot/recipes/standards/global/$($_.Name)" }
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
    $ctx = @{
        Type           = $Type
        BotRoot        = $botRoot
        ProcId         = $procId
        ProcessData    = $processData
        ModelName      = $claudeModelName
        SessionId      = $claudeSessionId
        Prompt         = $Prompt
        Description    = $Description
        ShowDebug      = [bool]$ShowDebug
        ShowVerbose    = [bool]$ShowVerbose
        ProjectRoot    = $projectRoot
        ControlDir     = $controlDir
        Settings       = $settings
        Model          = $Model
        NeedsInterview = [bool]$NeedsInterview
        FromPhase      = $FromPhase
        SkipPhaseIds   = $skipPhaseIds
    }
    & "$PSScriptRoot\modules\ProcessTypes\Invoke-KickstartProcess.ps1" -Context $ctx
} # --- Prompt-based types: planning, commit, task-creation ---
elseif ($Type -in @('planning', 'commit', 'task-creation')) {
    $ctx = @{
        Type        = $Type
        BotRoot     = $botRoot
        ProcId      = $procId
        ProcessData = $processData
        ModelName   = $claudeModelName
        SessionId   = $claudeSessionId
        Prompt      = $Prompt
        Description = $Description
        ShowDebug   = [bool]$ShowDebug
        ShowVerbose = [bool]$ShowVerbose
    }
    & "$PSScriptRoot\modules\ProcessTypes\Invoke-PromptProcess.ps1" -Context $ctx
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
