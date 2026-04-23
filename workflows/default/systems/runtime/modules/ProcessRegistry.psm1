<#
.SYNOPSIS
    Process lifecycle management module for dotbot runtime.
.DESCRIPTION
    Provides process registration, locking, activity logging, diagnostic
    logging, preflight checks, and task selection helpers.
    Extracted from launch-process.ps1 as part of v4 Phase 03 (#92).
#>

# --- Module-scope state (set via Initialize-ProcessRegistry) ---
$script:ProcessesDir = $null
$script:ControlDir = $null
$script:DiagLogPath = $null
$script:Settings = $null
$script:ProviderConfig = $null
$script:BotRoot = $null

function Initialize-ProcessRegistry {
    <#
    .SYNOPSIS
        Initialize module-scope state for ProcessRegistry functions.
    #>
    param(
        [Parameter(Mandatory)][string]$ProcessesDir,
        [Parameter(Mandatory)][string]$ControlDir,
        [string]$DiagLogPath,
        [object]$Settings,
        [object]$ProviderConfig,
        [string]$BotRoot
    )
    $script:ProcessesDir = $ProcessesDir
    $script:ControlDir = $ControlDir
    $script:DiagLogPath = $DiagLogPath
    $script:Settings = $Settings
    $script:ProviderConfig = $ProviderConfig
    $script:BotRoot = $BotRoot
}

function New-ProcessId {
    "proc-$([guid]::NewGuid().ToString().Substring(0,6))"
}

function Write-ProcessFile {
    param([string]$Id, [hashtable]$Data)
    $filePath = Join-Path $script:ProcessesDir "$Id.json"
    $tempFile = "$filePath.tmp"

    $retryCount = if ($script:Settings.operations.file_retry_count) { $script:Settings.operations.file_retry_count } else { 3 }
    $retryBaseMs = if ($script:Settings.operations.file_retry_base_ms) { $script:Settings.operations.file_retry_base_ms } else { 50 }
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
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                    Write-BotLog -Level Warn -Message "Write-ProcessFile FAILED for $Id after $retryCount retries" -Exception $_
                }
            }
        }
    }
}

function Write-ProcessActivity {
    param([string]$Id, [string]$ActivityType, [string]$Message)
    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        # Delegate to DotBotLog — handles per-process + global activity.jsonl
        Write-BotLog -Level Info -Message $Message -ProcessId $Id -Context @{ activity_type = $ActivityType }
    } else {
        # Fallback: direct file write if DotBotLog not loaded
        $logPath = Join-Path $script:ProcessesDir "$Id.activity.jsonl"
        $event = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            type = $ActivityType
            message = $Message
            task_id = $env:DOTBOT_CURRENT_TASK_ID
            phase = $env:DOTBOT_CURRENT_PHASE
        } | ConvertTo-Json -Compress

        $retryCount = if ($script:Settings.operations.file_retry_count) { $script:Settings.operations.file_retry_count } else { 3 }
        $retryBaseMs = if ($script:Settings.operations.file_retry_base_ms) { $script:Settings.operations.file_retry_base_ms } else { 50 }
        for ($r = 0; $r -lt $retryCount; $r++) {
            try {
                $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
                $sw.WriteLine($event)
                $sw.Close()
                $fs.Close()
                break
            } catch {
                if ($r -lt ($retryCount - 1)) { Start-Sleep -Milliseconds ($retryBaseMs * ($r + 1)) }
            }
        }
    }
}

function Test-ProcessStopSignal {
    param([string]$Id)
    $stopFile = Join-Path $script:ProcessesDir "$Id.stop"
    Test-Path $stopFile
}

function Acquire-ProcessLock {
    <#
    .SYNOPSIS
    Atomically acquire a process lock using FileMode.CreateNew.
    Returns $true if lock acquired, $false if another live process holds it.
    Automatically cleans stale locks (dead PIDs).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseApprovedVerbs',
        '',
        Justification = 'Acquire communicates lock semantics more clearly than the approved alternatives for this exported command.'
    )]
    param([string]$LockType)
    $lockPath = Join-Path $script:ControlDir "launch-$LockType.lock"

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
    $lockPath = Join-Path $script:ControlDir "launch-$LockType.lock"
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
    $lockPath = Join-Path $script:ControlDir "launch-$LockType.lock"
    $PID.ToString() | Set-Content $lockPath -NoNewline -Encoding utf8NoBOM
}

function Remove-ProcessLock {
    param([string]$LockType)
    $lockPath = Join-Path $script:ControlDir "launch-$LockType.lock"
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
    $providerExe = $script:ProviderConfig.executable
    $providerDisplay = $script:ProviderConfig.display_name
    $providerCmd = Get-Command $providerExe -ErrorAction SilentlyContinue
    if ($providerCmd) {
        $checks += "${providerExe}: OK"
    } else {
        $checks += "${providerExe}: MISSING - $providerDisplay CLI not found on PATH"
        $allPassed = $false
    }

    # .bot directory exists
    if (Test-Path $script:BotRoot) {
        $checks += ".bot: OK"
    } else {
        $checks += ".bot: MISSING - $($script:BotRoot) not found (run 'dotbot init' first)"
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
                Write-BotLog -Level Warn -Message "Failed to read analysing task: $($candidate.file_path)" -Exception $_
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
                        optional = $content.optional
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
                Write-BotLog -Level Warn -Message "Failed to read analysing task: $($candidate.file_path)" -Exception $_
            }
        }
    }

    # Second priority: prefer analysed tasks (ready for execution), then todo
    $wfFilterArgs = @{ prefer_analysed = $true; verbose = $Verbose.IsPresent }
    if ($WorkflowFilter) { $wfFilterArgs['workflow_filter'] = $WorkflowFilter }
    $result = Invoke-TaskGetNext -Arguments $wfFilterArgs
    return $result
}

function Test-DependencyDeadlock {
    param([string]$ProcessId)
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

function Test-WorkflowComplete {
    <#
    .SYNOPSIS
    Returns $true when there are zero pending tasks matching the given workflow filter.

    .DESCRIPTION
    A workflow-filtered task-runner is "complete" when every task tagged with its
    workflow name is in a terminal state (done/skipped/cancelled) — i.e. none remain
    in todo, analysed, analysing, in-progress, or needs-input. The runner should
    then exit cleanly rather than poll forever for tasks that will never arrive.

    Fixes the "ghost runner" deadlock where a workflow task-runner (e.g. the
    kickstart-via-repo runner) enters its wait loop after the last workflow-scoped
    task completes, keeps workflow_alive=true in /api/state, and blocks the UI's
    generic "Execute Tasks" Start button from launching a second runner to pick
    up non-workflow tasks created during the workflow run (e.g. gap-analysis
    tasks generated by Phase 5b).

    .PARAMETER WorkflowFilter
    The workflow name to match against each task's `workflow` field.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowFilter
    )

    $index = Get-TaskIndex
    $pendingPools = @(
        @($index.Todo.Values),
        @($index.Analysed.Values),
        @($index.Analysing.Values),
        @($index.InProgress.Values),
        @($index.NeedsInput.Values)
    )
    foreach ($pool in $pendingPools) {
        foreach ($task in $pool) {
            if ($task.workflow -eq $WorkflowFilter) {
                return $false
            }
        }
    }
    return $true
}

Export-ModuleMember -Function @(
    'Initialize-ProcessRegistry',
    'New-ProcessId',
    'Write-ProcessFile',
    'Write-ProcessActivity',
    'Test-ProcessStopSignal',
    'Acquire-ProcessLock',
    'Test-ProcessLock',
    'Set-ProcessLock',
    'Remove-ProcessLock',
    'Test-Preflight',
    'Add-YamlFrontMatter',
    'Get-NextTodoTask',
    'Get-NextWorkflowTask',
    'Test-DependencyDeadlock',
    'Test-WorkflowComplete'
)
