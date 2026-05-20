<#
.SYNOPSIS
Dispatch for plugin transition hooks (PRD-06).

Canonical PRD: docs/prds/PRD-06-hooks.md §Implementation Decisions.

Invokes each registered hook synchronously and inline with the caller's
Set-TaskStatus path. Per PRD:

  - Hooks fire AFTER the new status has been written to the task file,
    inside the task mutex (the runtime owns mutex acquisition; Dispatch
    just runs the hooks).
  - Each hook runs in a child runspace so max_duration can be enforced
    via Stop().
  - If a hook with abort_on_failure: true returns success=$false or times
    out, the caller is told to REVERT: the runtime writes the old status
    back and surfaces the failing hook's name + message.
  - Hook outcome (success/failure, duration, message) is reported back
    via the result so the caller can log it.

The Invoke-Hook contract from each hook's script.ps1 is defined in PRD-06
§Implementation Decisions — a single function taking $Task, $RunContext,
$FromStatus, $ToStatus and returning a hashtable with Success, Message,
Duration. See an example in any of the shipped hooks under
src/runtime/hooks/transitions/.

Loading note: a bare .ps1 with a top-level module-export call isn't a
real module. We turn it into one at dispatch time via New-Module against
a ScriptBlock built from the file contents — that creates a dynamic
module instance so the hook's exports (and any private helpers) behave
the way the PRD documents.
#>

function Invoke-SingleTransitionHook {
    <#
    .SYNOPSIS
    Run one hook's Invoke-Hook function under a timeout. Catches all faults
    and normalises the return to a single hashtable.

    .OUTPUTS
        @{
            name      = '<hook name>'
            success   = $true|$false
            message   = '<string>'
            duration  = <TimeSpan>
            timed_out = $true|$false
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Hook,                # one element from Get-HookRegistry
        [Parameter(Mandatory)] [hashtable]$Task,
        [Parameter(Mandatory)] [hashtable]$RunContext,
        [Parameter(Mandatory)] [string]$FromStatus,
        [Parameter(Mandatory)] [string]$ToStatus
    )

    $name = [string]$Hook.name
    $maxDuration = [int]$Hook.max_duration

    # Read the script once; we'll pass the contents into the child runspace
    # rather than re-reading from disk inside it. Avoids each dispatch needing
    # the child runspace to share the parent's working directory.
    $scriptContent = $null
    try {
        $scriptContent = Get-Content -LiteralPath $Hook.script_path -Raw -ErrorAction Stop
    } catch {
        return @{
            name      = $name
            success   = $false
            message   = "Hook '$name': could not read script.ps1 — $($_.Exception.Message)"
            duration  = [TimeSpan]::Zero
            timed_out = $false
        }
    }

    $runner = {
        param([string]$Content, [string]$HookName, [hashtable]$Task, [hashtable]$RunContext, [string]$FromStatus, [string]$ToStatus)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $sb = [ScriptBlock]::Create($Content)
            # New-Module against the script block produces a real dynamic
            # module — Export-ModuleMember inside the script works, and we
            # can invoke its private functions via `& $mod <Name>`.
            $mod = New-Module -Name ("DotbotHook_" + $HookName) -ScriptBlock $sb
            $hookResult = & $mod Invoke-Hook -Task $Task -RunContext $RunContext -FromStatus $FromStatus -ToStatus $ToStatus
        } catch {
            $sw.Stop()
            return @{
                success  = $false
                message  = $_.Exception.Message
                duration = $sw.Elapsed
            }
        }
        $sw.Stop()

        # Normalise the hook's return into a stable shape. Accept both
        # PascalCase (per PRD example) and lowercase keys.
        $success = $true
        $message = ''
        $hookDuration = $sw.Elapsed
        if ($hookResult -is [hashtable]) {
            if ($hookResult.ContainsKey('Success'))      { $success = [bool]$hookResult['Success'] }
            elseif ($hookResult.ContainsKey('success'))  { $success = [bool]$hookResult['success'] }
            if ($hookResult.ContainsKey('Message'))      { $message = [string]$hookResult['Message'] }
            elseif ($hookResult.ContainsKey('message'))  { $message = [string]$hookResult['message'] }
            if ($hookResult.ContainsKey('Duration')      -and $hookResult['Duration'] -is [TimeSpan]) { $hookDuration = $hookResult['Duration'] }
            elseif ($hookResult.ContainsKey('duration')  -and $hookResult['duration'] -is [TimeSpan]) { $hookDuration = $hookResult['duration'] }
        }
        return @{
            success  = $success
            message  = $message
            duration = $hookDuration
        }
    }

    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($runner)
    $null = $ps.AddArgument($scriptContent)
    $null = $ps.AddArgument($name)
    $null = $ps.AddArgument($Task)
    $null = $ps.AddArgument($RunContext)
    $null = $ps.AddArgument($FromStatus)
    $null = $ps.AddArgument($ToStatus)

    $outerSw = [System.Diagnostics.Stopwatch]::StartNew()
    $async = $ps.BeginInvoke()

    $completed = $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($maxDuration))
    $outerSw.Stop()

    if (-not $completed) {
        # Timeout — stop the runspace (PRD: "the runspace is forcibly stopped
        # and the hook is marked failed"). Stop() interrupts the running
        # script; EndInvoke will throw PipelineStoppedException which we eat.
        try { $ps.Stop() } catch { $null = $_ }
        try { $ps.Dispose() } catch { $null = $_ }
        return @{
            name      = $name
            success   = $false
            message   = "Hook '$name' exceeded max_duration of ${maxDuration}s and was stopped."
            duration  = $outerSw.Elapsed
            timed_out = $true
        }
    }

    $result = $null
    try {
        $result = $ps.EndInvoke($async) | Select-Object -First 1
    } catch {
        $result = @{ success = $false; message = $_.Exception.Message; duration = $outerSw.Elapsed }
    } finally {
        try { $ps.Dispose() } catch { $null = $_ }
    }

    if ($null -eq $result) {
        $result = @{ success = $false; message = "Hook '$name' produced no result."; duration = $outerSw.Elapsed }
    }

    return @{
        name      = $name
        success   = [bool]$result.success
        message   = [string]$result.message
        duration  = if ($result.duration -is [TimeSpan]) { $result.duration } else { $outerSw.Elapsed }
        timed_out = $false
    }
}

function Invoke-TransitionHooks {
    <#
    .SYNOPSIS
    Dispatch every hook whose target_statuses contains $ToStatus.

    .DESCRIPTION
    Called by the runtime's Set-TaskStatus handler AFTER the new status has
    been written to the task file (inside the task mutex). Walks the
    registry in declaration order and invokes each matching hook in its own
    child runspace with max_duration enforced.

    Stops at the first abort_on_failure: true hook that fails. Hooks
    flagged abort_on_failure: false always run to completion; their failure
    is recorded but does not abort.

    .OUTPUTS
        @{
            aborted          = $true|$false
            failing_hook     = '<name>' | $null
            failing_message  = '<string>' | $null
            hook_results     = @( <perHookResult>, ... )
        }
    #>
    [CmdletBinding()]
    param(
        [string]$BotRoot,
        [string]$HooksDir,
        [Parameter(Mandatory)] [string]$ToStatus,
        [Parameter(Mandatory)] [string]$FromStatus,
        [Parameter(Mandatory)] [hashtable]$Task,
        [hashtable]$RunContext
    )

    if (-not $RunContext) { $RunContext = @{} }

    # The runtime's BotRoot is useful context for hooks; thread it through.
    if ($BotRoot -and -not $RunContext.ContainsKey('BotRoot')) {
        $RunContext['BotRoot'] = $BotRoot
    }

    $registry = Get-HookRegistry -HooksDir $HooksDir -BotRoot $BotRoot
    $matching = Get-HooksForStatus -Registry $registry -ToStatus $ToStatus

    $results = @()
    $aborted = $false
    $failingHook = $null
    $failingMessage = $null

    foreach ($h in $matching) {
        $r = Invoke-SingleTransitionHook `
            -Hook        $h `
            -Task        $Task `
            -RunContext  $RunContext `
            -FromStatus  $FromStatus `
            -ToStatus    $ToStatus
        $results += ,$r

        if (-not $r.success -and [bool]$h.abort_on_failure) {
            $aborted        = $true
            $failingHook    = $r.name
            $failingMessage = $r.message
            # PRD §Implementation Decisions step 4: stop dispatching further
            # hooks once an abort fires. Downstream hooks would be operating
            # against a status the runtime is about to revert anyway.
            break
        }
    }

    return @{
        aborted         = $aborted
        failing_hook    = $failingHook
        failing_message = $failingMessage
        hook_results    = $results
    }
}

Export-ModuleMember -Function @(
    'Invoke-SingleTransitionHook'
    'Invoke-TransitionHooks'
)
