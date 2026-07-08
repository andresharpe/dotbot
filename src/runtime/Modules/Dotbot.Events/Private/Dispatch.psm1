<#
.SYNOPSIS
Dispatch for event-bus sinks.

Runs each sink subscribed to a published event. Two rules distinguish sinks
from transition hooks:

  - NON-ABORTING: a sink that fails or times out is logged and skipped. It
    never rolls back a task and never stops the other sinks for the same event.
  - OUT-OF-BAND: dispatch happens AFTER the event is durably logged, driven by
    the background consumer (a later step) — never inside a task's
    state-transition path.

Each sink runs in a child runspace so max_duration can be enforced via Stop().

The Invoke-Sink contract from each sink's script.ps1: a function taking
$Event (the event envelope) and $Context (a hashtable with BotRoot and the
resolved `events` settings section — so a sink can read its own config without
importing anything into its isolated runspace). A sink may return a hashtable
with Success/Message; returning nothing is treated as success — its work is the
side effect (POST a webhook, forward to the mothership, …).

Loading note: a bare .ps1 with a top-level Export-ModuleMember isn't a real
module. We turn it into one at dispatch time via New-Module against a
ScriptBlock built from the file contents, matching the Dotbot.Hook engine.
#>

function Invoke-SingleSink {
    <#
    .SYNOPSIS
    Run one sink's Invoke-Sink function under a timeout. Catches all faults and
    normalises the return to a single hashtable. Never throws.

    .OUTPUTS
        @{
            name      = '<sink name>'
            success   = $true|$false
            message   = '<string>'
            duration  = <TimeSpan>
            timed_out = $true|$false
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Sink,     # one element from Get-SinkRegistry
        [Parameter(Mandatory)] $Event,    # the event envelope (hashtable or pscustomobject)
        $Context                          # @{ BotRoot; Events } passed to the sink
    )

    $name = [string]$Sink.name
    $maxDuration = [int]$Sink.max_duration
    if ($null -eq $Context) { $Context = @{} }

    # Read the script once; pass the contents into the child runspace rather
    # than re-reading from disk inside it (avoids coupling to a working dir).
    $scriptContent = $null
    try {
        $scriptContent = Get-Content -LiteralPath $Sink.script_path -Raw -ErrorAction Stop
    } catch {
        return @{
            name      = $name
            success   = $false
            message   = "Sink '$name': could not read script.ps1 — $($_.Exception.Message)"
            duration  = [TimeSpan]::Zero
            timed_out = $false
        }
    }

    $runner = {
        param([string]$Content, [string]$SinkName, $Event, $Context)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $sb = [ScriptBlock]::Create($Content)
            # New-Module against the script block produces a real dynamic
            # module — Export-ModuleMember inside the script works, and we can
            # invoke its function via `& $mod <Name>`.
            $mod = New-Module -Name ("DotbotSink_" + $SinkName) -ScriptBlock $sb
            $sinkResult = & $mod Invoke-Sink -Event $Event -Context $Context
        } catch {
            $sw.Stop()
            return @{
                success  = $false
                message  = $_.Exception.Message
                duration = $sw.Elapsed
            }
        }
        $sw.Stop()

        # A sink that returns nothing is a success (the work is the side
        # effect). If it returns a hashtable, honour Success/Message (PascalCase
        # per contract, lowercase tolerated).
        $success = $true
        $message = ''
        $sinkDuration = $sw.Elapsed
        if ($sinkResult -is [hashtable]) {
            if ($sinkResult.ContainsKey('Success'))      { $success = [bool]$sinkResult['Success'] }
            elseif ($sinkResult.ContainsKey('success'))  { $success = [bool]$sinkResult['success'] }
            if ($sinkResult.ContainsKey('Message'))      { $message = [string]$sinkResult['Message'] }
            elseif ($sinkResult.ContainsKey('message'))  { $message = [string]$sinkResult['message'] }
        }
        return @{
            success  = $success
            message  = $message
            duration = $sinkDuration
        }
    }

    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($runner)
    $null = $ps.AddArgument($scriptContent)
    $null = $ps.AddArgument($name)
    $null = $ps.AddArgument($Event)
    $null = $ps.AddArgument($Context)

    $outerSw = [System.Diagnostics.Stopwatch]::StartNew()
    $async = $ps.BeginInvoke()

    $completed = $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($maxDuration))
    $outerSw.Stop()

    if (-not $completed) {
        # Timeout — forcibly stop the runspace. Non-aborting: the sink is
        # marked failed/timed-out and the caller moves on to the next sink.
        try { $ps.Stop() } catch { $null = $_ }
        try { $ps.Dispose() } catch { $null = $_ }
        return @{
            name      = $name
            success   = $false
            message   = "Sink '$name' exceeded max_duration of ${maxDuration}s and was stopped."
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
        $result = @{ success = $false; message = "Sink '$name' produced no result."; duration = $outerSw.Elapsed }
    }

    return @{
        name      = $name
        success   = [bool]$result.success
        message   = [string]$result.message
        duration  = if ($result.duration -is [TimeSpan]) { $result.duration } else { $outerSw.Elapsed }
        timed_out = $false
    }
}

function Invoke-EventSinks {
    <#
    .SYNOPSIS
    Dispatch every sink subscribed to a single event's type. Non-aborting:
    every matching sink runs regardless of what the others do.

    .DESCRIPTION
    Extracts the event's dotted `type`, finds the subscribed sinks, and runs
    each in its own time-boxed child runspace. A sink failure or timeout is
    captured in the results and never stops the remaining sinks — nor does it
    ever propagate back to the caller.

    .PARAMETER Event
    The event envelope — a hashtable (as published) or a pscustomobject (as
    parsed from the activity log by the consumer).

    .PARAMETER Registry
    A pre-discovered sink registry (from Get-SinkRegistry). When omitted, the
    registry is discovered from -SinksDir / -BotRoot. The consumer discovers
    once at startup and passes it here per event to avoid re-scanning disk.

    .PARAMETER Context
    The @{ BotRoot; Events } context handed to each sink. When omitted, a
    minimal @{ BotRoot = $BotRoot } is built.

    .OUTPUTS
        @{
            event_type = '<type>' | $null
            dispatched = <int matching sinks>
            results    = @( <perSinkResult>, ... )
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Event,
        $Registry,
        [string]$BotRoot,
        [string]$SinksDir,
        $Context
    )

    if ($null -eq $Context) { $Context = @{ BotRoot = $BotRoot } }

    $eventType = if ($Event -is [hashtable]) { [string]$Event['type'] } else { [string]$Event.type }
    if ([string]::IsNullOrWhiteSpace($eventType)) {
        return @{ event_type = $null; dispatched = 0; results = @() }
    }

    if ($null -eq $Registry) {
        $Registry = @(Get-SinkRegistry -SinksDir $SinksDir -BotRoot $BotRoot)
    }

    $matching = @(Get-SinksForEvent -Registry $Registry -EventType $eventType)

    $results = @()
    foreach ($s in $matching) {
        # Non-aborting belt-and-braces: Invoke-SingleSink already swallows sink
        # faults, but guard the dispatch call itself too so one bad sink can
        # never stop the others.
        $r = $null
        try {
            $r = Invoke-SingleSink -Sink $s -Event $Event -Context $Context
        } catch {
            $r = @{
                name      = [string]$s.name
                success   = $false
                message   = "Sink dispatch error: $($_.Exception.Message)"
                duration  = [TimeSpan]::Zero
                timed_out = $false
            }
        }
        $results += ,$r
    }

    return @{
        event_type = $eventType
        dispatched = $matching.Count
        results    = $results
    }
}

Export-ModuleMember -Function @(
    'Invoke-SingleSink'
    'Invoke-EventSinks'
)
