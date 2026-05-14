<#
.SYNOPSIS
Process lifecycle management for the dotbot runtime.

.DESCRIPTION
Two related concerns:

1. Process registry (business-level): tracks long-running task-runner and
   workflow processes in .control/processes/. Provides process IDs, file-based
   locks, activity logging, preflight checks, and task selection helpers.

2. Child process spawning (low-level): Start-DotbotChildProcess is the
   platform-aware pwsh subprocess launcher used by go.ps1, the UI APIs, and
   the CLI launchers.

All functions in this module are stateless. Paths are derived per call from
Get-DotbotProjectBotPath (which walks up from $PWD to find .bot/). Callers
may override by passing -BotRoot explicitly — useful for tests that operate
in a temp directory.
#>

if (-not (Get-Module Dotbot.Core)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Core' 'Dotbot.Core.psm1') -DisableNameChecking -Global
}

#region Path & retry-config helpers

function Resolve-DotbotBotRoot {
    param([string]$BotRoot)
    if ($BotRoot) { return $BotRoot }
    return (Get-DotbotProjectBotPath)
}

function Get-ProcessControlDir {
    param([string]$BotRoot)
    Join-Path (Resolve-DotbotBotRoot -BotRoot $BotRoot) ".control"
}

function Get-ProcessesDir {
    param([string]$BotRoot)
    Join-Path (Get-ProcessControlDir -BotRoot $BotRoot) "processes"
}

function Get-ProcessRetryConfig {
    # Returns @{ Count = N; BaseMs = M } from merged settings, or defaults.
    param([string]$BotRoot)
    $defaults = @{ Count = 3; BaseMs = 50 }
    $root = Resolve-DotbotBotRoot -BotRoot $BotRoot
    if (-not (Test-Path $root)) { return $defaults }
    try {
        $s = Get-MergedSettings -BotRoot $root
        if ($s.PSObject.Properties['operations'] -and $s.operations) {
            return @{
                Count  = if ($s.operations.file_retry_count)   { [int]$s.operations.file_retry_count }   else { 3 }
                BaseMs = if ($s.operations.file_retry_base_ms) { [int]$s.operations.file_retry_base_ms } else { 50 }
            }
        }
    } catch {
        # Best effort — fall through to defaults if Dotbot.Settings isn't loaded
        # or the file is malformed. Process logging is not critical-path.
    }
    return $defaults
}

#endregion

#region Process registry

function New-ProcessId {
    "proc-$([guid]::NewGuid().ToString().Substring(0,6))"
}

function Write-ProcessFile {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Data,
        [string]$BotRoot
    )
    $processesDir = Get-ProcessesDir -BotRoot $BotRoot
    $filePath = Join-Path $processesDir "$Id.json"
    $tempFile = "$filePath.tmp"
    $retry = Get-ProcessRetryConfig -BotRoot $BotRoot

    for ($r = 0; $r -lt $retry.Count; $r++) {
        try {
            $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
            Move-Item -Path $tempFile -Destination $filePath -Force -ErrorAction Stop
            return
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            if ($r -lt ($retry.Count - 1)) {
                Start-Sleep -Milliseconds ($retry.BaseMs * ($r + 1))
            } elseif (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Warn -Message "Write-ProcessFile FAILED for $Id after $($retry.Count) retries" -Exception $_
            }
        }
    }
}

function Write-ProcessActivity {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ActivityType,
        [Parameter(Mandatory)][string]$Message,
        [string]$BotRoot
    )
    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        # Delegate to Write-BotLog — handles per-process + global activity.jsonl
        Write-BotLog -Level Info -Message $Message -ProcessId $Id -Context @{ activity_type = $ActivityType }
        return
    }

    # Fallback: direct file write if Dotbot.Logging isn't loaded
    $processesDir = Get-ProcessesDir -BotRoot $BotRoot
    if (-not (Test-Path $processesDir)) {
        New-Item -Path $processesDir -ItemType Directory -Force | Out-Null
    }
    $logPath = Join-Path $processesDir "$Id.activity.jsonl"
    $event = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type      = $ActivityType
        message   = $Message
        task_id   = $env:DOTBOT_CURRENT_TASK_ID
        phase     = $env:DOTBOT_CURRENT_PHASE
    } | ConvertTo-Json -Compress

    $retry = Get-ProcessRetryConfig -BotRoot $BotRoot
    for ($r = 0; $r -lt $retry.Count; $r++) {
        try {
            Add-Content -LiteralPath $logPath -Value $event -Encoding utf8NoBOM -ErrorAction Stop
            return
        } catch {
            if ($r -lt ($retry.Count - 1)) { Start-Sleep -Milliseconds ($retry.BaseMs * ($r + 1)) }
        }
    }
}

function Test-ProcessStopSignal {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BotRoot
    )
    Test-Path (Join-Path (Get-ProcessesDir -BotRoot $BotRoot) "$Id.stop")
}

function Request-ProcessLock {
    <#
    .SYNOPSIS
    Atomically acquire a process lock using FileMode.CreateNew.
    Returns $true if lock acquired, $false if another live process holds it.
    Automatically cleans stale locks (dead PIDs).
    #>
    param(
        [Parameter(Mandatory)][string]$LockType,
        [string]$BotRoot
    )
    $lockPath = Join-Path (Get-ProcessControlDir -BotRoot $BotRoot) "launch-$LockType.lock"

    # Check for existing lock and validate the owner is alive
    if (Test-Path $lockPath) {
        $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
        if ($lockContent) {
            try {
                Get-Process -Id ([int]$lockContent.Trim()) -ErrorAction Stop | Out-Null
                return $false  # Held by a live process
            } catch {
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

function Test-ProcessLock {
    param(
        [Parameter(Mandatory)][string]$LockType,
        [string]$BotRoot
    )
    $lockPath = Join-Path (Get-ProcessControlDir -BotRoot $BotRoot) "launch-$LockType.lock"
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
    param(
        [Parameter(Mandatory)][string]$LockType,
        [string]$BotRoot
    )
    $lockPath = Join-Path (Get-ProcessControlDir -BotRoot $BotRoot) "launch-$LockType.lock"
    $PID.ToString() | Set-Content $lockPath -NoNewline -Encoding utf8NoBOM
}

function Remove-ProcessLock {
    param(
        [Parameter(Mandatory)][string]$LockType,
        [string]$BotRoot
    )
    $lockPath = Join-Path (Get-ProcessControlDir -BotRoot $BotRoot) "launch-$LockType.lock"
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

function Test-Preflight {
    param([string]$BotRoot)
    $root = Resolve-DotbotBotRoot -BotRoot $BotRoot
    $checks = @()
    $allPassed = $true

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $checks += "git: OK"
    } else {
        $checks += "git: MISSING - git not found on PATH"
        $allPassed = $false
    }

    $providerConfig = $null
    try { $providerConfig = Get-HarnessConfig } catch { }
    if ($providerConfig) {
        $providerExe = $providerConfig.executable
        $providerDisplay = $providerConfig.display_name
        $providerCmd = Get-Command $providerExe -ErrorAction SilentlyContinue
        if ($providerCmd) {
            $checks += "${providerExe}: OK"
        } else {
            $checks += "${providerExe}: MISSING - $providerDisplay CLI not found on PATH"
            $allPassed = $false
        }
    } else {
        $checks += "provider: MISSING - could not load harness config"
        $allPassed = $false
    }

    if (Test-Path $root) {
        $checks += ".bot: OK"
    } else {
        $checks += ".bot: MISSING - $root not found (run 'dotbot init' first)"
        $allPassed = $false
    }

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
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][hashtable]$Metadata
    )
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
    param([Parameter(Mandatory)][string]$ProcessId)
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
    #>
    param([Parameter(Mandatory)][string]$WorkflowFilter)

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

#endregion

#region Child process spawning

function Get-LogFilePaths {
    $logsDir = Get-DotbotProjectLogsPath
    $dir = Join-Path $logsDir 'processes'

    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)

    return @{
        OutLog = Join-Path $dir "$stamp-$suffix.out.log"
        ErrLog = Join-Path $dir "$stamp-$suffix.err.log"
    }
}

function Start-DotbotChildProcess {
    <#
    .SYNOPSIS
    Spawns a pwsh child process with platform-specific stdout/stderr handling.

    .DESCRIPTION
    Launches a long-running pwsh subprocess. On Windows it opens a new console window
    (configurable via -WindowStyle/-IsHeadless). On non-Windows it redirects stdout/stderr
    to per-process log files under .control/logs/processes/ because Start-Process cannot
    create a separate console there and the inherited streams may not be writable.

    This is the low-level spawner used by go.ps1, the UI APIs, and the CLI launchers.
    For tracking business-level dotbot processes (with locks, activity logs, and the
    process registry), use the New-ProcessId / Write-ProcessFile family in this module.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$File,

        [string[]]$FileArguments,

        [string]$WorkingDirectory,

        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle = 'Normal',

        [switch]$IsHeadless
    )

    $params = @{
        FilePath = 'pwsh'
        PassThru = $true
    }

    $argumentList = [System.Collections.Generic.List[string]]::new()
    $argumentList.Add('-NoProfile')
    $argumentList.Add('-File')
    $argumentList.Add($File)
    if ($FileArguments) {
        foreach ($argument in $FileArguments) {
            $argumentList.Add($argument)
        }
    }
    $params.ArgumentList = $argumentList.ToArray()
    if ($WorkingDirectory) {
        $params.WorkingDirectory = $WorkingDirectory
    }

    if ($IsWindows) {
        if ($IsHeadless) {
            $params.NoNewWindow = $true
        } else {
            $params.WindowStyle = $WindowStyle
        }
    } else {
        # On non-Windows, Start-Process can't create a separate console/window.
        # If the parent process has no usable stdout/stderr, the child can fail when
        # writing to inherited streams. Redirect to log files to give the child valid
        # stdout/stderr sinks.
        $logFiles = Get-LogFilePaths
        $params.RedirectStandardOutput = $logFiles.OutLog
        $params.RedirectStandardError = $logFiles.ErrLog
    }

    Start-Process @params
}

#endregion

Export-ModuleMember -Function @(
    # Process registry (business-level)
    'New-ProcessId'
    'Write-ProcessFile'
    'Write-ProcessActivity'
    'Test-ProcessStopSignal'
    'Request-ProcessLock'
    'Test-ProcessLock'
    'Set-ProcessLock'
    'Remove-ProcessLock'
    'Test-Preflight'
    'Add-YamlFrontMatter'
    'Get-NextTodoTask'
    'Get-NextWorkflowTask'
    'Test-DependencyDeadlock'
    'Test-WorkflowComplete'
    # Child process spawning (low-level)
    'Start-DotbotChildProcess'
)
