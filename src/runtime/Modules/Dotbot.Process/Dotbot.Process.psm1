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
        Write-BotLog -Level Debug -Message "Process retry config not available — using defaults" -Exception $_
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
    $entry = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type      = $ActivityType
        message   = $Message
        task_id   = $env:DOTBOT_CURRENT_TASK_ID
        phase     = $env:DOTBOT_CURRENT_PHASE
    } | ConvertTo-Json -Compress

    $retry = Get-ProcessRetryConfig -BotRoot $BotRoot
    for ($r = 0; $r -lt $retry.Count; $r++) {
        try {
            Add-Content -LiteralPath $logPath -Value $entry -Encoding utf8NoBOM -ErrorAction Stop
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
    try { $providerConfig = Get-HarnessConfig } catch { $null = $_ }
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

function _FlattenTask {
    <#
    .SYNOPSIS
    Project a TaskInstance into a flat dictionary. Executor knobs from
    extensions.executor.* and workflow metadata from extensions.workflow.*
    are surfaced at the top level so consumers can access them as $task.<field>.
    #>
    param(
        [Parameter(Mandatory)] $Content,
        [Parameter(Mandatory)] [string]$FilePath,
        [string]$StatusOverride
    )

    $exec = $null
    $wfx  = $null
    $runner = $null
    if ($Content.PSObject.Properties['extensions'] -and $Content.extensions) {
        if ($Content.extensions.PSObject.Properties['executor']) { $exec = $Content.extensions.executor }
        if ($Content.extensions.PSObject.Properties['workflow']) { $wfx  = $Content.extensions.workflow }
        if ($Content.extensions.PSObject.Properties['runner'])   { $runner = $Content.extensions.runner }
    }
    function _ext { param($Bag, [string]$Key)
        if ($null -eq $Bag) { return $null }
        if ($Bag -is [System.Collections.IDictionary]) {
            if ($Bag.Contains($Key)) { return $Bag[$Key] }
            return $null
        }
        if ($Bag.PSObject.Properties[$Key]) { return $Bag.PSObject.Properties[$Key].Value }
        return $null
    }

    $workflowName = $null
    if ($Content.PSObject.Properties['provenance'] -and $Content.provenance) {
        $workflowName = [string]$Content.provenance.workflow
    }

    $statusVal = if ($StatusOverride) { $StatusOverride } else { [string]$Content.status }

    return @{
        id                    = $Content.id
        name                  = $Content.name
        status                = $statusVal
        priority              = if ($null -ne $Content.priority) { $Content.priority } else { 0 }
        effort                = $Content.effort
        category              = $Content.category
        type                  = $Content.type
        description           = $Content.description
        dependencies          = $Content.dependencies
        outputs               = $Content.outputs
        acceptance_criteria   = $Content.acceptance_criteria
        created_at            = $Content.created_at
        updated_at            = $Content.updated_at
        completed_at          = $Content.completed_at
        file_path             = $FilePath
        workflow              = $workflowName
        script_path           = _ext $exec 'script_path'
        mcp_tool              = _ext $exec 'mcp_tool'
        mcp_args              = _ext $exec 'mcp_args'
        prompt                = _ext $exec 'prompt'
        skip_analysis         = _ext $exec 'skip_analysis'
        outputs_dir           = _ext $wfx 'outputs_dir'
        min_output_count      = _ext $wfx 'min_output_count'
        required_outputs      = _ext $wfx 'required_outputs'
        required_outputs_dir  = _ext $wfx 'required_outputs_dir'
        front_matter_docs     = _ext $wfx 'front_matter_docs'
        condition             = _ext $wfx 'condition'
        optional              = _ext $wfx 'optional'
        steps                 = _ext $wfx 'steps'
        applicable_agents     = _ext $wfx 'applicable_agents'
        applicable_standards  = _ext $wfx 'applicable_standards'
        needs_interview       = _ext $wfx 'needs_interview'
        questions_resolved    = _ext $runner 'questions_resolved'
        pending_question      = _ext $runner 'pending_question'
        claude_session_id     = _ext $runner 'claude_session_id'
    }
}

function Get-NextWorkflowTask {
    <#
    .SYNOPSIS
    Pick the next runnable task inside a WorkflowRun directory.

    .DESCRIPTION
    Filters tasks under workspace/tasks/workflow-runs/<dir>/ by status,
    applies dependency and manual-ignore checks, and returns the highest-
    priority eligible candidate. Resumed analysing-with-answers tasks come
    first, then analysed, then todo.

    Returns @{ success; task; message } where 'task' is a flat dictionary
    projected from the on-disk shape (see _FlattenTask).
    #>
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$RunId
    )

    if (-not (Get-Command Find-WorkflowRunDir -ErrorAction SilentlyContinue)) {
        return @{ success = $false; task = $null; message = "Dotbot.Workflow not loaded — Find-WorkflowRunDir unavailable." }
    }

    $runDir = Find-WorkflowRunDir -BotRoot $BotRoot -RunId $RunId
    if (-not $runDir -or -not (Test-Path -LiteralPath $runDir)) {
        return @{ success = $false; task = $null; message = "WorkflowRun '$RunId' not found on disk." }
    }

    $taskFiles = @(Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'run.json' })
    if ($taskFiles.Count -eq 0) {
        return @{ success = $true; task = $null; message = "No tasks in run $RunId." }
    }

    $allTasks = @()
    foreach ($f in $taskFiles) {
        try {
            $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
            $allTasks += @{ Content = $content; FilePath = $f.FullName }
        } catch {
            Write-BotLog -Level Warn -Message "Failed to parse task file: $($f.FullName)" -Exception $_
        }
    }

    # Done-set for dependency satisfaction.
    $doneSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $intentionalSkips = @('not-applicable','superseded','duplicate','already-satisfied','out-of-scope','condition-not-met')
    foreach ($t in $allTasks) {
        $c = $t.Content
        $satisfies = $false
        switch ([string]$c.status) {
            'done'      { $satisfies = $true }
            'cancelled' { $satisfies = $true }
            'split'     { $satisfies = $true }
            'skipped'   {
                $reason = $null
                if ($c.PSObject.Properties['extensions'] -and $c.extensions -and
                    $c.extensions.PSObject.Properties['runner']) {
                    $r = $c.extensions.runner
                    if ($r.PSObject.Properties['skip_reason']) { $reason = [string]$r.skip_reason }
                }
                if ($reason -and $intentionalSkips -contains $reason) { $satisfies = $true }
            }
        }
        if (-not $satisfies) { continue }
        if ($c.id)   { [void]$doneSet.Add([string]$c.id) }
        if ($c.name) {
            [void]$doneSet.Add([string]$c.name)
            $slug = (([string]$c.name) -replace '[^a-zA-Z0-9\s-]','' -replace '\s+','-').ToLowerInvariant()
            if ($slug) { [void]$doneSet.Add($slug) }
        }
    }

    function _AreDepsMet { param($Task, $Set)
        $deps = $Task.dependencies
        if (-not $deps) { return $true }
        $list = @($deps)
        if ($list.Count -eq 0) { return $true }
        foreach ($d in $list) {
            if (-not $d) { continue }
            $depStr = [string]$d
            if ($Set.Contains($depStr)) { continue }
            $slug = ($depStr -replace '[^a-zA-Z0-9\s-]','' -replace '\s+','-').ToLowerInvariant()
            if ($slug -and $Set.Contains($slug)) { continue }
            return $false
        }
        return $true
    }
    function _IsTaskIgnored { param($Task)
        if ($Task.PSObject.Properties['ignore'] -and $Task.ignore -and
            $Task.ignore.PSObject.Properties['manual'] -and $Task.ignore.manual -eq $true) {
            return $true
        }
        return $false
    }

    # Resume an analysing task whose clarification questions were just answered.
    foreach ($t in $allTasks) {
        $c = $t.Content
        if ([string]$c.status -ne 'analysing') { continue }
        $r = if ($c.PSObject.Properties['extensions'] -and $c.extensions -and
                 $c.extensions.PSObject.Properties['runner']) { $c.extensions.runner } else { $null }
        $hasQR = $r -and $r.PSObject.Properties['questions_resolved'] -and $r.questions_resolved -and @($r.questions_resolved).Count -gt 0
        $hasPQ = $r -and $r.PSObject.Properties['pending_question'] -and $r.pending_question
        if ($hasQR -and -not $hasPQ) {
            return @{
                success = $true
                task    = _FlattenTask -Content $c -FilePath $t.FilePath -StatusOverride 'analysing'
                message = "Resumed task (question answered): $($c.name)"
            }
        }
    }

    # Priority: analysed → todo. Ignore-state and dependency are applied per
    # status pass; blocked count surfaces in the no-task message.
    $blockedCount = 0
    foreach ($status in @('analysed','todo')) {
        $candidates = @($allTasks | Where-Object { [string]$_.Content.status -eq $status })
        $eligible = @()
        foreach ($cand in $candidates) {
            $c = $cand.Content
            if (_IsTaskIgnored -Task $c) { continue }
            if (-not (_AreDepsMet -Task $c -Set $doneSet)) { $blockedCount++; continue }
            $eligible += $cand
        }
        if ($eligible.Count -eq 0) { continue }
        $next = $eligible | Sort-Object @(
            @{ Expression = { if ($_.Content.priority -is [int] -or $_.Content.priority -is [long]) { -[int]$_.Content.priority } else { 0 } }; Ascending = $true }
            @{ Expression = { [string]$_.Content.created_at }; Ascending = $true }
        ) | Select-Object -First 1
        return @{
            success = $true
            task    = _FlattenTask -Content $next.Content -FilePath $next.FilePath -StatusOverride $status
            message = "Selected $status task: $($next.Content.name)"
        }
    }

    $msg = "No pending tasks available in run $RunId."
    if ($blockedCount -gt 0) { $msg += " $blockedCount task(s) blocked by unmet dependencies." }
    return @{ success = $true; task = $null; message = $msg }
}

function Test-DependencyDeadlock {
    <#
    .SYNOPSIS
    Detect runs where pending tasks are blocked by an unresolved framework-
    error skip — i.e. progress is impossible without operator action.
    #>
    param(
        [Parameter(Mandatory)][string]$ProcessId,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    if (-not (Get-Command Find-WorkflowRunDir -ErrorAction SilentlyContinue)) { return $false }
    $runDir = Find-WorkflowRunDir -BotRoot $BotRoot -RunId $RunId
    if (-not $runDir -or -not (Test-Path -LiteralPath $runDir)) { return $false }

    $allTasks = @(Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'run.json' } |
                    ForEach-Object { try { Get-Content -Path $_.FullName -Raw | ConvertFrom-Json } catch { $null } } |
                    Where-Object { $_ })
    if ($allTasks.Count -eq 0) { return $false }

    $frameworkReasons = @('non-recoverable','max-retries')
    $blockerNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $blockerLabels = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $allTasks) {
        if ([string]$t.status -ne 'skipped') { continue }
        $reason = $null
        if ($t.PSObject.Properties['extensions'] -and $t.extensions -and
            $t.extensions.PSObject.Properties['runner'] -and
            $t.extensions.runner.PSObject.Properties['skip_reason']) {
            $reason = [string]$t.extensions.runner.skip_reason
        }
        if (-not $reason -or ($frameworkReasons -notcontains $reason)) { continue }
        if ($t.id)   { [void]$blockerNames.Add([string]$t.id) }
        if ($t.name) {
            [void]$blockerNames.Add([string]$t.name)
            $slug = (([string]$t.name) -replace '[^a-zA-Z0-9\s-]','' -replace '\s+','-').ToLowerInvariant()
            if ($slug) { [void]$blockerNames.Add($slug) }
            $blockerLabels.Add([string]$t.name) | Out-Null
        }
    }
    if ($blockerNames.Count -eq 0) { return $false }

    $blocked = 0
    foreach ($t in $allTasks) {
        if ([string]$t.status -notin @('todo','analysed')) { continue }
        $deps = $t.dependencies
        if (-not $deps) { continue }
        foreach ($d in @($deps)) {
            if (-not $d) { continue }
            $depStr = [string]$d
            $slug = ($depStr -replace '[^a-zA-Z0-9\s-]','' -replace '\s+','-').ToLowerInvariant()
            if ($blockerNames.Contains($depStr) -or ($slug -and $blockerNames.Contains($slug))) {
                $blocked++
                break
            }
        }
    }
    if ($blocked -eq 0) { return $false }

    $deadlockMsg = "Dependency deadlock: $blocked pending task(s) blocked by framework-error skip(s) [$($blockerLabels -join ', ')]. Workflow cannot continue automatically — reset or re-implement the skipped tasks to unblock the queue."
    Write-Status $deadlockMsg -Type Error
    Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message $deadlockMsg
    return $true
}

function Test-WorkflowComplete {
    <#
    .SYNOPSIS
    Returns $true when every task in the given WorkflowRun directory is in a
    terminal status — i.e. there is nothing left for the runner to do.
    #>
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$RunId
    )

    if (-not (Get-Command Find-WorkflowRunDir -ErrorAction SilentlyContinue)) { return $false }
    $runDir = Find-WorkflowRunDir -BotRoot $BotRoot -RunId $RunId
    if (-not $runDir -or -not (Test-Path -LiteralPath $runDir)) { return $true }

    $pendingStatuses = @('todo','analysing','analysed','in-progress','needs-input')
    $taskFiles = @(Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'run.json' })
    foreach ($f in $taskFiles) {
        try {
            $t = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
            if ($pendingStatuses -contains ([string]$t.status)) { return $false }
        } catch { continue }
    }
    return $true
}

#endregion

#region Child process spawning

function Get-LogFileTarget {
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
        $logFiles = Get-LogFileTarget
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
    'Get-NextWorkflowTask'
    'Test-DependencyDeadlock'
    'Test-WorkflowComplete'
    # Child process spawning (low-level)
    'Start-DotbotChildProcess'
)
