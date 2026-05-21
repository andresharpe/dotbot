<#
.SYNOPSIS
Task → executor dispatch + timeout-enforced invocation.

Dispatch flow:
  1. Look up an executor by task.type. Missing → throw UnknownTaskType.
  2. Validate required_fields against the task. Missing → throw MissingExecutorField.
  3. Invoke the executor's Invoke-Executor in a child runspace.
  4. Enforce max_executor_duration; on timeout the runspace is forcibly stopped
     and a failure result is returned.
  5. Return the executor's result to the caller.

The runspace gives us two things at once: the runtime stays responsive while
the executor runs, and we have an Stop() handle the watchdog can use to kill
a runaway. Each invocation gets its own runspace — no shared state between
runs of the same executor, no pool of long-lived runspaces. Per-invocation
cost is small; per-invocation isolation is worth it.
#>

# ---------------------------------------------------------------------------
# Helpers shared with the dispatcher
# ---------------------------------------------------------------------------

function _Get-TaskField {
    # Lift a property from a task whether it's a hashtable / IDictionary or a
    # PSCustomObject. The HTTP layer deserialises with -AsHashtable so most
    # callers will pass a hashtable, but tests and direct callers can pass
    # PSCustomObjects too.
    param($Task, [string]$Name)

    if ($null -eq $Task) { return $null }
    if ($Task -is [System.Collections.IDictionary]) {
        if ($Task.Contains($Name)) { return $Task[$Name] }
        return $null
    }
    $prop = $Task.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function _Task-HasField {
    param($Task, [string]$Name)
    if ($null -eq $Task) { return $false }
    if ($Task -is [System.Collections.IDictionary]) { return $Task.Contains($Name) }
    return $null -ne $Task.PSObject.Properties[$Name]
}

function _Is-FieldPresent {
    # A required field is present iff the task carries the key AND the value
    # isn't null, empty string, or empty list. `description: ""` is not a
    # populated description.
    param($Task, [string]$Name)

    if (-not (_Task-HasField $Task $Name)) { return $false }
    $val = _Get-TaskField $Task $Name
    if ($null -eq $val) { return $false }
    if ($val -is [string])        { return -not [string]::IsNullOrWhiteSpace($val) }
    if ($val -is [System.Array])  { return @($val).Count -gt 0 }
    if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [System.Collections.IDictionary])) {
        return @($val).Count -gt 0
    }
    return $true
}

function Test-ExecutorRequiredFields {
    <#
    .SYNOPSIS
    Return the list of required executor fields that are missing on the task.
    Empty array means everything required is present.

    .DESCRIPTION
    Exposed so the runtime / callers can perform an explicit precondition
    check without invoking the executor. Invoke-TaskExecutor calls this
    before invocation and throws MissingExecutorField on any non-empty result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string[]]$RequiredFields
    )

    $missing = @()
    foreach ($f in $RequiredFields) {
        if (-not (_Is-FieldPresent $Task $f)) { $missing += $f }
    }
    return ,$missing
}

# ---------------------------------------------------------------------------
# Runspace invocation
# ---------------------------------------------------------------------------

function _Invoke-ExecutorScript {
    <#
    .SYNOPSIS
    Run an executor's Invoke-Executor in a child runspace under a watchdog.

    .DESCRIPTION
    Loads the script.ps1 into a fresh runspace, calls Invoke-Executor with
    -Task / -RunContext, and waits up to $TimeoutSeconds for it to finish.
    On timeout the runspace is forcibly stopped and a failure result is
    synthesised. On script-level exception the failure result carries the
    exception message.

    Result shape (matches the PRD's executor contract):
      @{ Success = <bool>; Message = <string>; ExitCode = <int>; ... }

    The dispatcher adds two diagnostic keys before returning:
      executor    = '<executor-name>'
      duration_ms = <wall-clock milliseconds>
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string]$ExecutorName,
        [Parameter(Mandatory)] [int]$TimeoutSeconds,
        [Parameter(Mandatory)] $Task,
        $RunContext
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Executor script.ps1 not found: '$ScriptPath'."
    }

    $scriptContent = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction Stop

    # Pass the task as a hashtable so the executor can index by string keys
    # without worrying about whether the request came in as JSON or as a PS
    # object. Same for RunContext.
    $taskHash = if ($Task -is [System.Collections.IDictionary]) {
        $Task
    } elseif ($Task -is [PSCustomObject]) {
        $bag = @{}
        foreach ($p in $Task.PSObject.Properties) { $bag[$p.Name] = $p.Value }
        $bag
    } else {
        $Task
    }
    $ctxHash = if ($null -eq $RunContext) {
        @{}
    } elseif ($RunContext -is [System.Collections.IDictionary]) {
        $RunContext
    } elseif ($RunContext -is [PSCustomObject]) {
        $bag = @{}
        foreach ($p in $RunContext.PSObject.Properties) { $bag[$p.Name] = $p.Value }
        $bag
    } else {
        $RunContext
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    # Load the executor's script.ps1 as an in-memory module so
    # Export-ModuleMember is valid where it actually appears. Then call
    # Invoke-Executor *inside the module's session state* via
    # `& $module Invoke-Executor`, which keeps the executor's helper
    # functions private to its own scope.
    [void]$ps.AddScript({
        param($scriptContent, $executorName, $task, $ctx)
        $sb = [scriptblock]::Create($scriptContent)
        $module = New-Module -ScriptBlock $sb -Name ("dotbot-executor-" + $executorName)
        try {
            if (-not (& $module Get-Command -Name 'Invoke-Executor' -ErrorAction SilentlyContinue)) {
                throw "Executor '$executorName' does not define Invoke-Executor."
            }
            & $module Invoke-Executor -Task $task -RunContext $ctx
        } finally {
            try { Remove-Module $module -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
    })
    [void]$ps.AddArgument($scriptContent)
    [void]$ps.AddArgument($ExecutorName)
    [void]$ps.AddArgument($taskHash)
    [void]$ps.AddArgument($ctxHash)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $async = $ps.BeginInvoke()
    $timedOut = $false
    $output = $null
    $errorMessage = $null
    try {
        if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            # Watchdog: PRD User Story 6 requires we kill runaway executors so
            # the author doesn't have to write their own timeout code.
            $timedOut = $true
            try { $ps.Stop() } catch { $null = $_ }
        } else {
            try {
                $output = $ps.EndInvoke($async)
            } catch {
                $errorMessage = $_.Exception.Message
            }
            # Surface script-level errors (Write-Error / non-terminating).
            if (-not $errorMessage -and $ps.HadErrors -and $ps.Streams.Error.Count -gt 0) {
                $errorMessage = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
            }
        }
    } finally {
        $sw.Stop()
        try { $ps.Dispose() } catch { $null = $_ }
        try { $runspace.Dispose() } catch { $null = $_ }
    }

    if ($timedOut) {
        return [ordered]@{
            Success     = $false
            Message     = "Executor '$ExecutorName' exceeded max_executor_duration of $TimeoutSeconds second(s)."
            ExitCode    = 124       # Conventional timeout exit code (matches GNU `timeout`).
            TimedOut    = $true
            executor    = $ExecutorName
            duration_ms = $sw.ElapsedMilliseconds
        }
    }

    if ($errorMessage) {
        return [ordered]@{
            Success     = $false
            Message     = "Executor '$ExecutorName' threw: $errorMessage"
            ExitCode    = 1
            executor    = $ExecutorName
            duration_ms = $sw.ElapsedMilliseconds
        }
    }

    # Normalise the executor's return value. PRD says Invoke-Executor returns
    #   @{ Success = ...; Message = ...; ExitCode = ... }
    # A single-result pipeline that returns one hashtable surfaces as that
    # hashtable; multi-emit returns surface as an array. Pick the last
    # hashtable-shaped value as the canonical result. The double @( ) wrap
    # is intentional — piping through Where-Object will unwrap a single-element
    # array back to a scalar, and indexing into a scalar hashtable like an
    # array silently returns $null for the .Count==1 case.
    $resultObj = $null
    if ($null -ne $output) {
        $candidates = @(@($output) | Where-Object { $null -ne $_ })
        for ($i = $candidates.Count - 1; $i -ge 0; $i--) {
            $c = $candidates[$i]
            if ($c -is [System.Collections.IDictionary] -or $c -is [PSCustomObject]) {
                $resultObj = $c
                break
            }
        }
        if (-not $resultObj -and $candidates.Count -gt 0) { $resultObj = $candidates[-1] }
    }

    if (-not $resultObj) {
        return [ordered]@{
            Success     = $false
            Message     = "Executor '$ExecutorName' did not return a result hashtable."
            ExitCode    = 1
            executor    = $ExecutorName
            duration_ms = $sw.ElapsedMilliseconds
        }
    }

    # Stamp diagnostic keys without overwriting executor-supplied values.
    $bag = @{}
    if ($resultObj -is [System.Collections.IDictionary]) {
        foreach ($k in $resultObj.Keys) { $bag[$k] = $resultObj[$k] }
    } else {
        foreach ($p in $resultObj.PSObject.Properties) { $bag[$p.Name] = $p.Value }
    }
    if (-not $bag.ContainsKey('executor'))    { $bag['executor']    = $ExecutorName }
    if (-not $bag.ContainsKey('duration_ms')) { $bag['duration_ms'] = $sw.ElapsedMilliseconds }
    return $bag
}

# ---------------------------------------------------------------------------
# Public dispatcher
# ---------------------------------------------------------------------------

function Invoke-TaskExecutor {
    <#
    .SYNOPSIS
    Dispatch a task to its executor and return the executor's result.

    .DESCRIPTION
    Dispatch flow:
      1. Look up by task.type. Missing → throw 'UnknownTaskType'.
      2. Check required_fields. Missing → throw 'MissingExecutorField'.
      3. Invoke in a child runspace with the executor's max_executor_duration.
      4. Return the (possibly synthesised) result hashtable.

    Errors are surfaced as throws so the runtime / caller can map them onto
    HTTP responses or audit-log entries with full context. Look at the
    exception's Data dictionary for ExecutorName / Field / TaskType keys.

    .PARAMETER Task
    The TaskInstance hashtable (must carry at least 'type'). Anything else
    the executor's required_fields list is checked against the task too.

    .PARAMETER RunContext
    Hashtable passed straight through to Invoke-Executor. PRD calls for
    the WorkflowRun record + a RuntimeClient handle. The dispatcher doesn't
    inspect it.

    .PARAMETER Registry
    A hashtable returned by Get-ExecutorRegistry. When omitted, the dispatcher
    builds one from -ExecutorsDir.

    .PARAMETER ExecutorsDir
    Used only when -Registry is omitted: where to scan for executors.

    .PARAMETER TimeoutOverrideSeconds
    Test-only knob. When set, ignores metadata.max_executor_duration and
    enforces this value instead. Production callers should let the executor's
    own metadata declare the timeout.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Registry')]
    param(
        [Parameter(Mandatory)] $Task,

        $RunContext,

        [Parameter(ParameterSetName = 'Registry', Mandatory)]
        [hashtable]$Registry,

        [Parameter(ParameterSetName = 'Dir', Mandatory)]
        [string]$ExecutorsDir,

        [int]$TimeoutOverrideSeconds
    )

    if (-not $Registry) {
        $Registry = Get-ExecutorRegistry -ExecutorsDir $ExecutorsDir
    }

    $taskType = _Get-TaskField $Task 'type'
    if (-not $taskType) {
        # Treat absent / empty type the same as unknown — the dispatcher
        # cannot route without it.
        $err = New-Object System.InvalidOperationException "UnknownTaskType: task has no 'type' field."
        $err.Data['Kind']     = 'UnknownTaskType'
        $err.Data['TaskType'] = ''
        throw $err
    }

    if (-not $Registry.ContainsKey($taskType)) {
        $known = (@($Registry.Keys) | Sort-Object) -join ', '
        if (-not $known) { $known = '(none)' }
        $err = New-Object System.InvalidOperationException "UnknownTaskType: no executor registered for task type '$taskType' (known: $known)."
        $err.Data['Kind']     = 'UnknownTaskType'
        $err.Data['TaskType'] = $taskType
        throw $err
    }

    $entry      = $Registry[$taskType]
    $metadata   = $entry.metadata
    $required   = @($metadata['required_fields'])
    $taskId     = _Get-TaskField $Task 'id'
    $executorNm = $metadata['name']

    if ($required.Count -gt 0) {
        $missing = Test-ExecutorRequiredFields -Task $Task -RequiredFields $required
        if ($missing.Count -gt 0) {
            $err = New-Object System.InvalidOperationException "MissingExecutorField: executor '$executorNm' requires field(s) [$($missing -join ', ')] on task '$taskId'."
            $err.Data['Kind']         = 'MissingExecutorField'
            $err.Data['ExecutorName'] = $executorNm
            $err.Data['TaskType']     = $taskType
            $err.Data['Missing']      = $missing
            throw $err
        }
    }

    $timeout = if ($PSBoundParameters.ContainsKey('TimeoutOverrideSeconds')) {
        [int]$TimeoutOverrideSeconds
    } else {
        [int]$metadata['max_executor_duration']
    }

    return _Invoke-ExecutorScript `
        -ScriptPath     $entry.script_path `
        -ExecutorName   $executorNm `
        -TimeoutSeconds $timeout `
        -Task           $Task `
        -RunContext     $RunContext
}

Export-ModuleMember -Function @(
    'Test-ExecutorRequiredFields'
    'Invoke-TaskExecutor'
)
