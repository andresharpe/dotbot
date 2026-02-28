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
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('analysis', 'execution', 'workflow', 'kickstart', 'analyse', 'planning', 'commit', 'task-creation')]
    [string]$Type,

    [string]$TaskId,
    [string]$Prompt,
    [switch]$Continue,
    [ValidateSet('Opus', 'Sonnet', 'Haiku')]
    [string]$Model,
    [switch]$ShowDebug,
    [switch]$ShowVerbose,
    [int]$MaxTasks = 0,
    [string]$Description,
    [string]$ProcessId,
    [switch]$NeedsInterview
)

# --- Configuration ---
$modelMap = @{
    'Opus'   = 'claude-opus-4-6'
    'Sonnet' = 'claude-sonnet-4-5-20250929'
    'Haiku'  = 'claude-haiku-4-5-20251001'
}

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
Import-Module "$PSScriptRoot\ClaudeCLI\ClaudeCLI.psm1" -Force
Import-Module "$PSScriptRoot\modules\DotBotTheme.psm1" -Force
$t = Get-DotBotTheme

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

    # MCP tool functions
    . "$PSScriptRoot\..\mcp\tools\session-initialize\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-get-state\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-get-stats\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-update\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-increment-completed\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\task-get-next\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\task-mark-in-progress\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\task-mark-skipped\script.ps1"
}

if ($Type -in @('analysis', 'workflow')) {
    . "$PSScriptRoot\..\mcp\tools\task-mark-analysing\script.ps1"
}

# Load settings for model defaults
$settingsPath = Join-Path $botRoot "defaults\settings.default.json"
$settings = @{ execution = @{ model = 'Opus' }; analysis = @{ model = 'Opus' } }
if (Test-Path $settingsPath) {
    try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch {}
}

# Resolve model (parameter > settings > default)
if (-not $Model) {
    $Model = switch ($Type) {
        { $_ -in @('analysis', 'kickstart') } { if ($settings.analysis?.model) { $settings.analysis.model } else { 'Opus' } }
        'workflow' { if ($settings.execution?.model) { $settings.execution.model } else { 'Opus' } }
        default    { if ($settings.execution?.model) { $settings.execution.model } else { 'Opus' } }
    }
}

$claudeModelName = $modelMap[$Model]
$env:CLAUDE_MODEL = $claudeModelName

# --- Process Registry ---

function New-ProcessId {
    "proc-$([guid]::NewGuid().ToString().Substring(0,6))"
}

function Write-ProcessFile {
    param([string]$Id, [hashtable]$Data)
    $filePath = Join-Path $processesDir "$Id.json"
    $tempFile = "$filePath.tmp"
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
    Move-Item -Path $tempFile -Destination $filePath -Force
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

    $maxRetries = 3
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
            $sw.WriteLine($event)
            $sw.Close()
            $fs.Close()
            break
        } catch {
            if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
        }
    }

    # Also write to global activity.jsonl for oscilloscope backward compat
    try { Write-ActivityLog -Type $ActivityType -Message $Message } catch {}
}

function Test-ProcessStopSignal {
    param([string]$Id)
    $stopFile = Join-Path $processesDir "$Id.stop"
    Test-Path $stopFile
}

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

    # Claude CLI on PATH
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $checks += "claude: OK"
    } else {
        $checks += "claude: MISSING - Claude CLI not found on PATH"
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
                if ($content.questions_resolved -and $content.questions_resolved.Count -gt 0 -and -not $content.pending_question) {
                    Write-Status "Found resumed task (question answered): $($candidate.name)" -Type Info
                    $taskObj = @{
                        id = $content.id
                        name = $content.name
                        status = 'analysing'
                        priority = [int]$content.priority
                        effort = $content.effort
                        category = $content.category
                    }
                    if ($Verbose.IsPresent) {
                        $taskObj.description = $content.description
                        $taskObj.dependencies = $content.dependencies
                        $taskObj.acceptance_criteria = $content.acceptance_criteria
                        $taskObj.steps = $content.steps
                        $taskObj.applicable_agents = $content.applicable_agents
                        $taskObj.applicable_standards = $content.applicable_standards
                        $taskObj.file_path = $candidate.file_path
                        $taskObj.questions_resolved = $content.questions_resolved
                        $taskObj.claude_session_id = $content.claude_session_id
                        $taskObj.needs_interview = $content.needs_interview
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

# --- Crash Trap ---
# Catch unexpected termination and persist process state before exit
trap {
    if ($procId -and $processData -and $processData.status -in @('running', 'starting')) {
        $processData.status = 'stopped'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = "Unexpected termination: $($_.Exception.Message)"
        try { Write-ProcessFile -Id $procId -Data $processData } catch {}
        try { Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process terminated unexpectedly: $($_.Exception.Message)" } catch {}
    }
    try { Remove-ProcessLock -LockType $Type } catch {}
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

# --- Single-instance guard ---
if (Test-ProcessLock -LockType $Type) {
    $existingPid = (Get-Content (Join-Path $controlDir "launch-$Type.lock") -Raw).Trim()
    Write-Warning "Another $Type process is already running (PID $existingPid). Exiting."
    exit 1
}
Set-ProcessLock -LockType $Type

# --- Initialize Process ---
$procId = if ($ProcessId) { $ProcessId } else { New-ProcessId }
$sessionId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
$claudeSessionId = [System.Guid]::NewGuid().ToString()

# Set process ID env var for dual-write activity logging in ClaudeCLI
$env:DOTBOT_PROCESS_ID = $procId

$processData = @{
    id              = $procId
    type            = $Type
    status          = 'starting'
    task_id         = $TaskId
    task_name       = $null
    continue        = [bool]$Continue
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
    description     = $Description
}

Write-ProcessFile -Id $procId -Data $processData

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
                if ($Continue) {
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
            Write-Status "Task: $($task.name)" -Type Success
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Started task: $($task.name)"

            # Mark execution task immediately to prevent analysis from picking it up
            if ($Type -eq 'execution') {
                Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
                Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null
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

            # Generate new Claude session ID per task
            $claudeSessionId = [System.Guid]::NewGuid().ToString()
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
                    -StandardsList $standardsList

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

                $branchForPrompt = "main"
                $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

                # Build resolved questions context for resumed tasks
                $isResumedTask = $task.status -eq 'analysing'
                $resolvedQuestionsContext = ""
                if ($isResumedTask -and $task.questions_resolved) {
                    $resolvedQuestionsContext = "`n## Previously Resolved Questions`n`n"
                    $resolvedQuestionsContext += "This task was previously paused for human input. The following questions have been answered:`n`n"
                    foreach ($q in $task.questions_resolved) {
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

                    Invoke-ClaudeStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                # Check rate limit
                $rateLimitMsg = Get-LastRateLimitInfo
                if ($rateLimitMsg) {
                    Write-Status "Rate limit detected!" -Type Warn
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
                                        break
                                    }
                                } catch {}
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
                        } catch {}
                        break
                    }
                }

                if ($attemptNumber -ge $maxRetriesPerTask) {
                    Write-Status "Max retries exhausted" -Type Error
                    if ($Type -eq 'execution') {
                        try {
                            Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "max-retries" } | Out-Null
                        } catch {}
                    }
                    break
                }
            }
            } finally {
                if ($worktreePath) { Pop-Location }
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
                try { Remove-ClaudeSession -SessionId $claudeSessionId -ProjectRoot $projectRoot | Out-Null } catch {}
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"

                # Clean up worktree for failed/skipped tasks to unblock analysis
                if ($Type -eq 'execution' -and $worktreePath) {
                    Write-Status "Cleaning up worktree for failed task..." -Type Info
                    Remove-Junctions -WorktreePath $worktreePath | Out-Null
                    git -C $projectRoot worktree remove $worktreePath --force 2>$null
                    git -C $projectRoot branch -D $branchName 2>$null
                    Initialize-WorktreeMap -BotRoot $botRoot
                    $map = Read-WorktreeMap
                    $map.Remove($task.id)
                    Write-WorktreeMap -Map $map
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
                    } catch {}
                }
            }

            # Continue to next task?
            if (-not $Continue) { break }

            # Clear task ID for next iteration
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null

            # Delay between tasks
            Write-Phosphor "Waiting 3s before next task..." -Color Bezel
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
            try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch {}
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

    $tasksProcessed = 0
    $maxRetriesPerTask = 2
    $consecutiveFailureThreshold = 3

    # Update process status to running
    $processData.status = 'running'
    Write-ProcessFile -Id $procId -Data $processData

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

            # ===== Pick next task =====
            Write-Status "Fetching next task..." -Type Process
            Reset-TaskIndex

            # Check resumed tasks (answered questions) first, then todo
            $taskResult = Get-NextTodoTask -Verbose

            if (-not $taskResult.success) {
                Write-Status "Error fetching task: $($taskResult.message)" -Type Error
                break
            }

            if (-not $taskResult.task) {
                if ($Continue) {
                    $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                    Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for new tasks..."

                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $procId) { break }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $procId -Data $processData
                        Reset-TaskIndex
                        $taskResult = Get-NextTodoTask -Verbose
                        if ($taskResult.task) { $foundTask = $true; break }
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
            $env:DOTBOT_CURRENT_TASK_ID = $task.id
            Write-Status "Task: $($task.name)" -Type Success

            # ===== PHASE 1: Analysis =====
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
            $analysisPrompt = $analysisPrompt -replace '\{\{BRANCH_NAME\}\}', 'main'

            # Build resolved questions context for resumed tasks
            $isResumedTask = $task.status -eq 'analysing'
            $resolvedQuestionsContext = ""
            if ($isResumedTask -and $task.questions_resolved) {
                $resolvedQuestionsContext = "`n## Previously Resolved Questions`n`n"
                $resolvedQuestionsContext += "This task was previously paused for human input. The following questions have been answered:`n`n"
                foreach ($q in $task.questions_resolved) {
                    $resolvedQuestionsContext += "**Q:** $($q.question)`n"
                    $resolvedQuestionsContext += "**A:** $($q.answer)`n`n"
                }
                $resolvedQuestionsContext += "Use these answers to guide your analysis. The task is already in ``analysing`` status - do NOT call ``task_mark_analysing`` again.`n"
            }

            # Use analysis model from settings
            $analysisModel = if ($settings.analysis?.model) { $settings.analysis.model } else { 'Opus' }
            $analysisModelName = $modelMap[$analysisModel]

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

            # Invoke Claude for analysis
            $analysisSessionId = [System.Guid]::NewGuid().ToString()
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

                    Invoke-ClaudeStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Analysis error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                # Handle rate limit
                $rateLimitMsg = Get-LastRateLimitInfo
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
                            } catch {}
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
            try { Remove-ClaudeSession -SessionId $analysisSessionId -ProjectRoot $projectRoot | Out-Null } catch {}

            if (-not $analysisSuccess) {
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
            if ($analysisOutcome -ne 'analysed') {
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

            # ===== PHASE 2: Execution =====
            $env:DOTBOT_CURRENT_PHASE = 'execution'
            $processData.heartbeat_status = "Executing: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution phase started: $($task.name)"

            # Re-read task data (analysis may have enriched it)
            Reset-TaskIndex
            $freshTask = Invoke-TaskGetNext -Arguments @{ verbose = $true }
            if ($freshTask.task -and $freshTask.task.id -eq $task.id) {
                $task = $freshTask.task
            }

            # Mark in-progress
            Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
            Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

            # Worktree setup
            $worktreePath = $null
            $branchName = $null
            $wtInfo = Get-TaskWorktreeInfo -TaskId $task.id -BotRoot $botRoot
            if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
                $worktreePath = $wtInfo.worktree_path
                $branchName = $wtInfo.branch_name
                Write-Status "Using worktree: $worktreePath" -Type Info
            } else {
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

            # Use execution model from settings
            $executionModel = if ($settings.execution?.model) { $settings.execution.model } else { 'Opus' }
            $executionModelName = $modelMap[$executionModel]

            # Build execution prompt
            $executionPrompt = Build-TaskPrompt `
                -PromptTemplate $executionPromptTemplate `
                -Task $task `
                -SessionId $sessionId `
                -ProductMission $productMission `
                -EntityModel $entityModel `
                -StandardsList $standardsList

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

            # Invoke Claude for execution
            $executionSessionId = [System.Guid]::NewGuid().ToString()
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

                    Invoke-ClaudeStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Execution error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData

                # Handle rate limit
                $rateLimitMsg = Get-LastRateLimitInfo
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
                if ($completionCheck.completed) {
                    Write-Status "Task completed!" -Type Complete
                    Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                    $taskSuccess = $true
                    break
                }

                # Task not completed - handle failure
                $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout "" -Stderr "" -TimedOut $false
                if (-not $failureReason.recoverable) {
                    Write-Status "Non-recoverable failure - skipping" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "non-recoverable" } | Out-Null
                    } catch {}
                    break
                }

                if ($attemptNumber -ge $maxRetriesPerTask) {
                    Write-Status "Max retries exhausted" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "max-retries" } | Out-Null
                    } catch {}
                    break
                }
            }
            } finally {
                if ($worktreePath) { Pop-Location }
            }

            # Clean up execution session
            try { Remove-ClaudeSession -SessionId $executionSessionId -ProjectRoot $projectRoot | Out-Null } catch {}

            # Update process data
            $env:DOTBOT_CURRENT_TASK_ID = $null
            $env:CLAUDE_SESSION_ID = $null

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
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed (analyse+execute): $($task.name)"
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"

                # Clean up worktree for failed/skipped tasks
                if ($worktreePath) {
                    Write-Status "Cleaning up worktree for failed task..." -Type Info
                    Remove-Junctions -WorktreePath $worktreePath | Out-Null
                    git -C $projectRoot worktree remove $worktreePath --force 2>$null
                    git -C $projectRoot branch -D $branchName 2>$null
                    Initialize-WorktreeMap -BotRoot $botRoot
                    $map = Read-WorktreeMap
                    $map.Remove($task.id)
                    Write-WorktreeMap -Map $map
                }

                # Update session failure counters
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
                } catch {}
            }

            # Continue to next task?
            if (-not $Continue) { break }

            # Clear task ID for next iteration
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null

            # Delay between tasks
            Write-Phosphor "Waiting 3s before next task..." -Color Bezel
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

        try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch {}
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

    try {
        # ===== Phase 0: Interview loop (if requested) =====
        if ($NeedsInterview) {
            $processData.heartbeat_status = "Phase 0: Interviewing for requirements"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase 0 — interviewing for requirements..."
            Write-Header "Phase 0: Interview"

            # Load interview prompt template
            $interviewWorkflowPath = Join-Path $botRoot "prompts\workflows\00-kickstart-interview.md"
            $interviewWorkflow = ""
            if (Test-Path $interviewWorkflowPath) {
                $interviewWorkflow = Get-Content $interviewWorkflowPath -Raw
            }

            # Check for briefing files
            $briefingDir = Join-Path $productDir "briefing"
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
            $questionsPath = Join-Path $productDir "clarification-questions.json"
            $summaryPath = Join-Path $productDir "interview-summary.md"

            # Use Opus for interview quality
            $interviewModel = $modelMap['Opus']

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

$Prompt
$interviewFileRefs
$previousContext

## Instructions

Review all context above. Decide whether to write clarification-questions.json (more questions needed) or interview-summary.md (all clear). Write exactly one file to .bot/workspace/product/.
"@

                Write-Status "Interview round $interviewRound..." -Type Process
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Interview round $interviewRound"

                $interviewSessionId = [System.Guid]::NewGuid().ToString()
                $streamArgs = @{
                    Prompt = $interviewPrompt
                    Model = $interviewModel
                    SessionId = $interviewSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                Invoke-ClaudeStream @streamArgs

                # Check what Opus wrote
                if (Test-Path $summaryPath) {
                    Write-Status "Interview complete — summary written" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Interview complete after $interviewRound round(s)"

                    # Add YAML front matter to interview summary
                    $meta = @{
                        generated_at = (Get-Date).ToUniversalTime().ToString("o")
                        model = $interviewModel
                        process_id = $procId
                        phase = "phase-0-interview"
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
                    Write-ProcessFile -Id $procId -Data $processData
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for user answers (round $interviewRound, $($questions.Count) questions)"

                    # Poll for answers file
                    $answersPath = Join-Path $productDir "clarification-answers.json"
                    if (Test-Path $answersPath) { Remove-Item $answersPath -Force }

                    while (-not (Test-Path $answersPath)) {
                        if (Test-ProcessStopSignal -Id $procId) {
                            Write-Status "Stop signal received during interview" -Type Error
                            $processData.status = 'stopped'
                            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                            $processData.pending_questions = $null
                            Write-ProcessFile -Id $procId -Data $processData
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
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "User skipped interview at round $interviewRound"
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
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Received answers for round $interviewRound"

                    # Clean up for next iteration
                    Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
                    Remove-Item $answersPath -Force -ErrorAction SilentlyContinue

                    # Reset process status
                    $processData.status = 'running'
                    $processData.pending_questions = $null
                    $processData.interview_round = $null
                    $processData.heartbeat_status = "Phase 0: Processing interview answers"
                    Write-ProcessFile -Id $procId -Data $processData
                } else {
                    # Neither file written — something went wrong, proceed without
                    Write-Status "Interview round produced no output — proceeding" -Type Warn
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Interview round $interviewRound produced no output — skipping"
                    break
                }
            } while ($true)

            # Ensure status is running for Phase 1
            $processData.status = 'running'
            $processData.pending_questions = $null
            $processData.interview_round = $null
            Write-ProcessFile -Id $procId -Data $processData
        }

        # ===== Phase 1: Create product documents =====
        $processData.heartbeat_status = "Phase 1: Creating product documents"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase 1 — creating product documents..."
        Write-Header "Phase 1: Product Documents"

        $workflowContent = ""
        $workflowPath = Join-Path $botRoot "prompts\workflows\01-plan-product.md"
        if (Test-Path $workflowPath) {
            $workflowContent = Get-Content $workflowPath -Raw
        }

        # Check for briefing files
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

        # Check for interview summary from Phase 0
        $interviewContext = ""
        $interviewSummaryPath = Join-Path $productDir "interview-summary.md"
        if (Test-Path $interviewSummaryPath) {
            $interviewContext = @"

## Interview Summary

An interview-summary.md file exists in .bot/workspace/product/ containing the user's clarified requirements with both verbatim answers and expanded interpretation. **Read this file** and use it to guide your decisions — it reflects the user's confirmed preferences for platform, architecture, technology, domain model, and other key directions.
"@
        }

        $phase1Prompt = @"
You are a product planning assistant for the dotbot autonomous development system.

Your task is to create the foundational product documents for a new project based on the user's description.

Follow this workflow for guidance on document structure:
$workflowContent

User's project description:
$Prompt
$fileRefs
$interviewContext

Instructions:
1. Read any briefing files listed above and any existing project files (README.md, etc.) for additional context
2. If an interview-summary.md file exists in .bot/workspace/product/, read it carefully — it contains clarified requirements from the user
3. Create these product documents directly by writing files to .bot/workspace/product/:
   - mission.md - What the product is, core principles, goals. MUST start with a section titled "Executive Summary" as the first heading.
   - tech-stack.md - Technologies, versions, infrastructure decisions
   - entity-model.md - Data model, entities, relationships. Include a Mermaid.js erDiagram block showing entities and their relationships visually.
4. Do NOT create tasks, ask questions, or use task management tools. Just create the documents directly.
5. Write comprehensive, well-structured markdown documents based on what you know from the user's description and any attached files.
6. Make reasonable inferences where details are missing - the user can refine later.

IMPORTANT: The mission.md file MUST begin with an "Executive Summary" section (## Executive Summary) as the very first content after the title. This is required for the UI to detect that product planning is complete.
"@

        $streamArgs = @{
            Prompt = $phase1Prompt
            Model = $claudeModelName
            SessionId = $claudeSessionId
            PersistSession = $false
        }
        if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ClaudeStream @streamArgs

        # Verify product docs were created
        $hasDocs = (Test-Path (Join-Path $productDir "mission.md")) -and
                   (Test-Path (Join-Path $productDir "tech-stack.md")) -and
                   (Test-Path (Join-Path $productDir "entity-model.md"))

        if (-not $hasDocs) {
            throw "Phase 1 failed: product documents were not created"
        }

        # Add YAML front matter to Phase 1 product docs
        $phase1Meta = @{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            model = $claudeModelName
            process_id = $procId
            phase = "phase-1-product-docs"
            generator = "dotbot-kickstart"
        }
        foreach ($docName in @("mission.md", "tech-stack.md", "entity-model.md")) {
            $docPath = Join-Path $productDir $docName
            if (Test-Path $docPath) {
                Add-YamlFrontMatter -FilePath $docPath -Metadata $phase1Meta
            }
        }

        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 1 complete — product documents created"

        # Checkpoint: commit product documents
        Write-Status "Committing phase 1 artifacts..." -Type Info
        git -C $projectRoot add .bot/workspace/product/ 2>$null
        git -C $projectRoot commit --quiet -m "chore(kickstart): phase 1 — product documents" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 1 checkpoint committed"
        } else {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 1 checkpoint: nothing to commit"
        }

        # ===== Phase 2a: Generate task groups =====
        $processData.heartbeat_status = "Phase 2a: Planning task groups"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase 2a — planning task groups..."
        Write-Header "Phase 2a: Task Groups"

        $groupsWorkflow = ""
        $groupsWorkflowPath = Join-Path $botRoot "prompts\workflows\03a-plan-task-groups.md"
        if (Test-Path $groupsWorkflowPath) {
            $groupsWorkflow = Get-Content $groupsWorkflowPath -Raw
        }

        $phase2aPrompt = @"
$groupsWorkflow

Work autonomously. Do not ask questions. Read the product documents and create task-groups.json.

CRITICAL: Your ONLY job is to create task-groups.json in .bot/workspace/product/.
Do NOT read other workflow files from the prompts/workflows/ directory.
Do NOT use task management MCP tools. Do NOT create individual tasks.
Do NOT read or follow 03-plan-roadmap.md or 04-new-tasks.md — those are for other process types.
"@

        # New session for Phase 2a
        $claudeSessionId = [System.Guid]::NewGuid().ToString()
        $streamArgs = @{
            Prompt = $phase2aPrompt
            Model = $claudeModelName
            SessionId = $claudeSessionId
            PersistSession = $false
        }
        if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ClaudeStream @streamArgs

        # Verify task-groups.json was created
        $groupsPath = Join-Path $productDir "task-groups.json"
        if (-not (Test-Path $groupsPath)) {
            throw "Phase 2a failed: task-groups.json was not created"
        }

        # Inject metadata into task-groups.json
        $groupsJson = Get-Content $groupsPath -Raw | ConvertFrom-Json
        $groupsJson | Add-Member -NotePropertyName "generated_at" -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o") -Force
        $groupsJson | Add-Member -NotePropertyName "model" -NotePropertyValue $claudeModelName -Force
        $groupsJson | Add-Member -NotePropertyName "process_id" -NotePropertyValue $procId -Force
        $groupsJson | Add-Member -NotePropertyName "generator" -NotePropertyValue "dotbot-kickstart" -Force
        $groupsJson | ConvertTo-Json -Depth 10 | Set-Content -Path $groupsPath -Encoding utf8NoBOM

        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 2a complete — task groups planned"

        # ===== Generate roadmap-overview.md (deterministic, no LLM) =====
        try {
            $costDefaults = @{ hourly_rate = 50; ai_cost_per_task = 0.50; ai_speedup_factor = 10; currency = "USD" }
            $costConfig = if ($settings.costs) { $settings.costs } else { $costDefaults }
            $hourlyRate = if ($costConfig.hourly_rate) { [decimal]$costConfig.hourly_rate } else { 50 }
            $aiCostPerTask = if ($costConfig.ai_cost_per_task) { [decimal]$costConfig.ai_cost_per_task } else { 0.50 }
            $aiSpeedupFactor = if ($costConfig.ai_speedup_factor) { [decimal]$costConfig.ai_speedup_factor } else { 10 }
            $currency = if ($costConfig.currency) { $costConfig.currency } else { "USD" }

            $groupsData = Get-Content $groupsPath -Raw | ConvertFrom-Json
            $sortedGroups = $groupsData.groups | Sort-Object { $_.order }

            $totalEffortDays = ($sortedGroups | ForEach-Object { if ($_.effort_days) { $_.effort_days } else { 3 } } | Measure-Object -Sum).Sum
            $totalTasks = ($sortedGroups | ForEach-Object { $_.estimated_task_count } | Measure-Object -Sum).Sum

            $roadmap = [System.Collections.ArrayList]::new()
            [void]$roadmap.Add("---")
            [void]$roadmap.Add("generated_at: `"$((Get-Date).ToUniversalTime().ToString("o"))`"")
            [void]$roadmap.Add("model: `"$claudeModelName`"")
            [void]$roadmap.Add("process_id: `"$procId`"")
            [void]$roadmap.Add("phase: `"phase-2b-roadmap`"")
            [void]$roadmap.Add("generator: `"dotbot-kickstart`"")
            [void]$roadmap.Add("---")
            [void]$roadmap.Add("")
            [void]$roadmap.Add("# Roadmap Overview")
            [void]$roadmap.Add("")
            [void]$roadmap.Add("**Project:** $($groupsData.project_name)")
            [void]$roadmap.Add("**Generated:** $(Get-Date -Format 'yyyy-MM-dd')")
            [void]$roadmap.Add("**Groups:** $($sortedGroups.Count) | **Estimated Tasks:** $totalTasks | **Effort:** $totalEffortDays developer-days")
            [void]$roadmap.Add("")

            # Executive summary from mission.md
            $missionPath = Join-Path $productDir "mission.md"
            if (Test-Path $missionPath) {
                $missionContent = Get-Content $missionPath -Raw
                if ($missionContent -match '(?ms)## Executive Summary\s*\n(.+?)(?=\n## |\z)') {
                    [void]$roadmap.Add("## Executive Summary")
                    [void]$roadmap.Add("")
                    [void]$roadmap.Add($matches[1].Trim())
                    [void]$roadmap.Add("")
                } elseif ($missionContent -match '(?m)^#[^#].*\n+(.+)') {
                    [void]$roadmap.Add("## Executive Summary")
                    [void]$roadmap.Add("")
                    [void]$roadmap.Add($matches[1].Trim())
                    [void]$roadmap.Add("")
                }
            }

            # Mermaid gantt chart — AI-assisted timeline
            [void]$roadmap.Add("## Timeline (AI-Assisted)")
            [void]$roadmap.Add("")
            [void]$roadmap.Add('```mermaid')
            [void]$roadmap.Add("gantt")
            [void]$roadmap.Add("    title $($groupsData.project_name) — AI-Assisted Timeline")
            [void]$roadmap.Add("    dateFormat YYYY-MM-DD")
            [void]$roadmap.Add("    axisFormat %b %d")
            [void]$roadmap.Add("")

            $today = Get-Date
            $groupEndDates = @{}

            foreach ($group in $sortedGroups) {
                $effortDays = if ($group.effort_days) { [int]$group.effort_days } else { 3 }
                $aiDays = [math]::Ceiling($effortDays / $aiSpeedupFactor)
                if ($aiDays -lt 1) { $aiDays = 1 }

                # Determine start date based on dependencies
                $startDate = $today
                if ($group.depends_on -and $group.depends_on.Count -gt 0) {
                    foreach ($depId in $group.depends_on) {
                        if ($groupEndDates.ContainsKey($depId) -and $groupEndDates[$depId] -gt $startDate) {
                            $startDate = $groupEndDates[$depId]
                        }
                    }
                }

                $endDate = $startDate.AddDays($aiDays)
                $groupEndDates[$group.id] = $endDate

                $startStr = $startDate.ToString("yyyy-MM-dd")
                # Sanitize name for Mermaid (remove special chars)
                $safeName = $group.name -replace '[:#]', ''

                [void]$roadmap.Add("    section $safeName")
                [void]$roadmap.Add("    $safeName :$($group.id), $startStr, ${aiDays}d")
            }

            [void]$roadmap.Add('```')
            [void]$roadmap.Add("")

            # Human vs AI comparison table
            [void]$roadmap.Add("## Human vs AI-Assisted Comparison")
            [void]$roadmap.Add("")
            [void]$roadmap.Add("| Group | Human (days) | AI (days) | Human Cost | AI Cost | Speedup |")
            [void]$roadmap.Add("|-------|-------------|-----------|------------|---------|---------|")

            $totalHumanDays = 0
            $totalAiDays = 0
            $totalHumanCost = [decimal]0
            $totalAiCost = [decimal]0

            foreach ($group in $sortedGroups) {
                $effortDays = if ($group.effort_days) { [int]$group.effort_days } else { 3 }
                $aiDays = [math]::Ceiling($effortDays / $aiSpeedupFactor)
                if ($aiDays -lt 1) { $aiDays = 1 }
                $taskCount = if ($group.estimated_task_count) { [int]$group.estimated_task_count } else { 3 }

                $humanCost = [decimal]($effortDays * 8 * $hourlyRate)
                $aiLaborCost = [decimal]($aiDays * 8 * $hourlyRate)
                $aiApiCost = [decimal]($taskCount * $aiCostPerTask)
                $groupAiCost = $aiLaborCost + $aiApiCost

                $totalHumanDays += $effortDays
                $totalAiDays += $aiDays
                $totalHumanCost += $humanCost
                $totalAiCost += $groupAiCost

                $speedup = if ($aiDays -gt 0) { "{0:N1}x" -f ($effortDays / $aiDays) } else { "N/A" }
                $safeName = $group.name -replace '\|', '/'

                [void]$roadmap.Add("| $safeName | $effortDays | $aiDays | $currency $("{0:N0}" -f $humanCost) | $currency $("{0:N0}" -f $groupAiCost) | $speedup |")
            }

            $totalSpeedup = if ($totalAiDays -gt 0) { "{0:N1}x" -f ($totalHumanDays / $totalAiDays) } else { "N/A" }
            [void]$roadmap.Add("| **Total** | **$totalHumanDays** | **$totalAiDays** | **$currency $("{0:N0}" -f $totalHumanCost)** | **$currency $("{0:N0}" -f $totalAiCost)** | **$totalSpeedup** |")
            [void]$roadmap.Add("")

            $savings = $totalHumanCost - $totalAiCost
            $savingsPercent = if ($totalHumanCost -gt 0) { [math]::Round(($savings / $totalHumanCost) * 100) } else { 0 }
            [void]$roadmap.Add("**Estimated savings:** $currency $("{0:N0}" -f $savings) ($savingsPercent%)")
            [void]$roadmap.Add("")

            # Implementation groups detail
            [void]$roadmap.Add("## Implementation Groups")
            [void]$roadmap.Add("")

            foreach ($group in $sortedGroups) {
                $depStr = if ($group.depends_on -and $group.depends_on.Count -gt 0) {
                    " | Depends on: $(($group.depends_on) -join ', ')"
                } else { "" }

                [void]$roadmap.Add("### $($group.order). $($group.name)")
                [void]$roadmap.Add("")
                [void]$roadmap.Add("$($group.description)")
                [void]$roadmap.Add("")
                $effortDays = if ($group.effort_days) { $group.effort_days } else { "?" }
                [void]$roadmap.Add("- **Estimated tasks:** $($group.estimated_task_count) | **Effort:** $effortDays days$depStr")
                [void]$roadmap.Add("")
            }

            $overviewPath = Join-Path $productDir "roadmap-overview.md"
            $roadmap -join "`n" | Set-Content -Path $overviewPath -Encoding UTF8
            Write-Status "Roadmap overview generated: $overviewPath" -Type Success
        } catch {
            Write-Status "Warning: could not generate roadmap overview: $($_.Exception.Message)" -Type Warn
        }

        # Checkpoint: commit task groups + roadmap
        Write-Status "Committing phase 2a artifacts..." -Type Info
        git -C $projectRoot add .bot/workspace/product/ 2>$null
        git -C $projectRoot commit --quiet -m "chore(kickstart): phase 2a — task groups and roadmap" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 2a checkpoint committed"
        } else {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 2a checkpoint: nothing to commit"
        }

        # ===== Phase 2b: Expand task groups =====
        $processData.heartbeat_status = "Phase 2b: Expanding task groups into tasks"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase 2b — expanding task groups..."
        Write-Header "Phase 2b: Task Group Expansion"

        $expandScript = Join-Path $botRoot "systems\runtime\expand-task-groups.ps1"
        & $expandScript -BotRoot $botRoot -Model $claudeModelName -ProcessId $procId

        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 2b complete — all task groups expanded"

        # Checkpoint: commit expanded tasks
        Write-Status "Committing phase 2b artifacts..." -Type Info
        git -C $projectRoot add .bot/workspace/tasks/ 2>$null
        git -C $projectRoot commit --quiet -m "chore(kickstart): phase 2b — expanded task roadmap" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 2b checkpoint committed"
        } else {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase 2b checkpoint: nothing to commit"
        }

        # Done
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

# --- Analyse type: scan existing repo, create product docs only ---
elseif ($Type -eq 'analyse') {
    if (-not $Description) { $Description = "Analyse existing project" }

    $processData.status = 'running'
    $processData.workflow = "analyse-pipeline"
    $processData.description = $Description
    $processData.heartbeat_status = $Description
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "$Description started"

    $productDir = Join-Path $botRoot "workspace\product"

    try {
        # ===== Phase 1 (only phase): Scan repo and create product documents =====
        $processData.heartbeat_status = "Scanning repository and creating product documents"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Scanning repository and creating product documents..."
        Write-Header "Analyse: Product Documents"

        $workflowContent = ""
        $workflowPath = Join-Path $botRoot "prompts\workflows\01-plan-product.md"
        if (Test-Path $workflowPath) {
            $workflowContent = Get-Content $workflowPath -Raw
        }

        # Build optional user guidance
        $userGuidance = ""
        if ($Prompt) {
            $userGuidance = @"

## User Guidance

The user has provided the following guidance for the analysis:
$Prompt
"@
        }

        $analysePrompt = @"
You are a product analysis assistant for the dotbot autonomous development system.

Your task is to thoroughly analyse an EXISTING codebase and create foundational product documents that describe what this project is and how it works.

Follow this workflow for guidance on document structure:
$workflowContent

## Repo Scan Instructions

This is an existing project with real code. You MUST explore it thoroughly before writing documents:

1. **Directory structure**: List the full directory tree to understand project layout
2. **README and docs**: Read README.md, any docs/ folder, CONTRIBUTING.md, etc.
3. **Config files**: Read package.json, Cargo.toml, go.mod, *.csproj, pyproject.toml, or whatever build/dependency files exist
4. **Entry points**: Identify and read main entry points (main.*, index.*, app.*, Program.*, etc.)
5. **Source code**: Browse through src/, lib/, or equivalent directories to understand the architecture
6. **Tests**: Check test files to understand expected behavior
7. **Data/schemas**: Look for database migrations, schema files, API definitions

Base your product documents entirely on what you discover in the codebase. Do NOT guess or use generic templates.
$userGuidance

Instructions:
1. Scan the repository thoroughly using the steps above
2. Create these product documents directly by writing files to .bot/workspace/product/:
   - mission.md - What the product is, core principles, goals (derived from actual code). MUST start with a section titled "Executive Summary" as the first heading.
   - tech-stack.md - Technologies, versions, infrastructure decisions (from actual dependencies)
   - entity-model.md - Data model, entities, relationships (from actual code/schemas). Include a Mermaid.js erDiagram block.
3. Do NOT create tasks, ask questions, or use task management tools. Just create the documents directly.
4. Write comprehensive, well-structured markdown documents based on what you discover.

IMPORTANT: The mission.md file MUST begin with an "Executive Summary" section (## Executive Summary) as the very first content after the title. This is required for the UI to detect that product planning is complete.
"@

        $streamArgs = @{
            Prompt = $analysePrompt
            Model = $claudeModelName
            SessionId = $claudeSessionId
            PersistSession = $false
        }
        if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ClaudeStream @streamArgs

        # Verify product docs were created
        $hasDocs = (Test-Path (Join-Path $productDir "mission.md")) -and
                   (Test-Path (Join-Path $productDir "tech-stack.md")) -and
                   (Test-Path (Join-Path $productDir "entity-model.md"))

        if (-not $hasDocs) {
            throw "Analyse failed: product documents were not created"
        }

        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analyse complete - product documents created"

        # Done - no Phase 2 (no task groups or expansion for analyse)
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

# --- Prompt-based types: planning, commit, task-creation ---
elseif ($Type -in @('planning', 'commit', 'task-creation')) {
    # Determine workflow template
    $workflowFile = switch ($Type) {
        'planning'      { Join-Path $botRoot "prompts\workflows\03-plan-roadmap.md" }
        'commit'        { Join-Path $botRoot "prompts\workflows\02-commit-and-push.md" }
        'task-creation' { Join-Path $botRoot "prompts\workflows\04-new-tasks.md" }
    }

    $processData.workflow = switch ($Type) {
        'planning'      { "03-plan-roadmap.md" }
        'commit'        { "02-commit-and-push.md" }
        'task-creation' { "04-new-tasks.md" }
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

        Invoke-ClaudeStream @streamArgs

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
Remove-ProcessLock -LockType $Type
$env:DOTBOT_PROCESS_ID = $null
$env:DOTBOT_CURRENT_TASK_ID = $null
$env:DOTBOT_CURRENT_PHASE = $null

# Output process ID for caller to use
Write-Host ""
Write-Status "Process $procId finished with status: $($processData.status)" -Type Info

# 5-second countdown before window closes
Write-Host ""
for ($i = 5; $i -ge 1; $i--) {
    Write-Host "`r  Window closing in ${i}s..." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host ""
