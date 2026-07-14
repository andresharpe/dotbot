<#
.SYNOPSIS
Background consumer for the event bus.

Tails <BotRoot>/.control/activity.jsonl by BYTE CURSOR — the same read
technique the /api/activity/tail endpoint uses — and dispatches each event to
its matching sinks (out-of-band: only after the event is durably on disk).

Delivery is AT-LEAST-ONCE: the persisted cursor advances only AFTER a batch has
been dispatched, so a crash mid-batch re-delivers that batch on the next tick
rather than dropping it. The cursor lives at <BotRoot>/.control/events-cursor.json
and survives restarts, so events appended while no runtime was running (e.g. a
detached CLI `tasks run`) are delivered from the persisted offset when the next
runtime starts — delayed, never dropped.

This module is self-contained: it computes the activity-log path itself rather
than importing Dotbot.Runtime, so the dependency stays one-directional
(Dotbot.Runtime hosts Dotbot.Events, never the reverse).

The runspace lifecycle (Start/Stop-EventConsumer) mirrors the runtime's
ControlPlaneClient: a cooperative stop flag + explicit Stop()/Dispose().
#>

# ─── Paths ──────────────────────────────────────────────────────────────────

function _Get-EventActivityLogPath {
    # Duplicated (not imported from Dotbot.Runtime) to keep the dependency
    # one-directional. Must stay in sync with Get-ActivityLogPath.
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path $BotRoot (Join-Path '.control' 'activity.jsonl')
}

function Get-EventCursorPath {
    <#
    .SYNOPSIS
    Resolve <BotRoot>/.control/events-cursor.json (the persisted byte offset).
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path $BotRoot (Join-Path '.control' 'events-cursor.json')
}

# ─── Cursor persistence ─────────────────────────────────────────────────────

function Read-EventCursor {
    <#
    .SYNOPSIS
    Return the persisted byte offset, or $null when no cursor exists yet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$BotRoot)

    $path = Get-EventCursorPath -BotRoot $BotRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $obj -and $null -ne $obj.offset) { return [long]$obj.offset }
    } catch {
        # Corrupt cursor → treat as fresh; the caller re-initialises.
    }
    return $null
}

function Save-EventCursor {
    <#
    .SYNOPSIS
    Persist the byte offset. Atomic (temp + move) so a crash can't leave a
    half-written cursor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [long]$Offset
    )

    $path = Get-EventCursorPath -BotRoot $BotRoot
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ([ordered]@{ offset = $Offset } | ConvertTo-Json -Compress)
    $tmp  = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Initialize-EventConsumerCursor {
    <#
    .SYNOPSIS
    Ensure a cursor exists. On the very first start (no cursor) seed it to the
    current end of the activity log so historical events are NOT replayed to
    sinks (a webhook re-POSTing the whole history would be surprising). From
    then on the persisted cursor carries forward across restarts.

    .OUTPUTS
    The byte offset the consumer will start reading from.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$BotRoot)

    $existing = Read-EventCursor -BotRoot $BotRoot
    if ($null -ne $existing) { return $existing }

    $logPath = _Get-EventActivityLogPath -BotRoot $BotRoot
    $eof = 0L
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $eof = [long]((Get-Item -LiteralPath $logPath).Length)
    }
    Save-EventCursor -BotRoot $BotRoot -Offset $eof
    return $eof
}

# ─── Byte-cursor read ───────────────────────────────────────────────────────

function Read-EventBatch {
    <#
    .SYNOPSIS
    Read all complete JSON lines from $Offset to EOF and report the new byte
    position. Mirrors the /api/activity/tail streaming read (FileStream opened
    ReadWrite-shared, Seek to the offset, read to EOF, report Position).

    .OUTPUTS
        @{ events = @(<parsed pscustomobject>, ...); position = <long> }

    Malformed lines are skipped. A cursor past EOF (log truncated/rotated)
    restarts from 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$LogPath,
        [Parameter(Mandatory)] [long]$Offset
    )

    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return @{ events = @(); position = $Offset }
    }

    $events = @()
    $newPos = $Offset
    $fs = $null
    $reader = $null
    try {
        $fs = [System.IO.FileStream]::new(
            $LogPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)

        $start = if ($Offset -gt $fs.Length) { 0L } else { $Offset }
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)

        $reader = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false))
        $text = $reader.ReadToEnd()
        $newPos = $fs.Position

        foreach ($line in ($text -split "`n")) {
            $trimmed = $line.Trim()
            if (-not $trimmed) { continue }
            try { $events += ($trimmed | ConvertFrom-Json -ErrorAction Stop) } catch { }
        }
    } finally {
        # Disposing the reader disposes the underlying stream too.
        if ($reader) { $reader.Dispose() } elseif ($fs) { $fs.Dispose() }
    }

    return @{ events = @($events); position = $newPos }
}

# ─── One delivery tick ──────────────────────────────────────────────────────

function _Get-MergedSettingsSafe {
    # Resolve the full merged settings for the sink Context. Guarded so the
    # tick still works when Dotbot.Settings isn't loaded (isolated tests).
    param([Parameter(Mandatory)] [string]$BotRoot)

    if (-not (Get-Command Get-MergedSettings -ErrorAction SilentlyContinue)) { return $null }
    try {
        return Get-MergedSettings -BotRoot $BotRoot
    } catch {
        $null = $_
    }
    return $null
}

function Invoke-EventConsumerTick {
    <#
    .SYNOPSIS
    Read the batch since the persisted cursor, dispatch each event to its
    sinks, then advance the cursor. At-least-once: the cursor is saved only
    after dispatch.

    .PARAMETER Registry
    Pre-discovered sink registry (Get-SinkRegistry). Passed in so the tick does
    not re-scan disk on every cycle.

    .OUTPUTS
        @{ processed = <int events>; dispatched = <int sink invocations>; position = <long> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        $Registry,
        [string]$LogPath
    )

    if (-not $LogPath) { $LogPath = _Get-EventActivityLogPath -BotRoot $BotRoot }

    $offset = Read-EventCursor -BotRoot $BotRoot
    if ($null -eq $offset) { $offset = 0L }

    $batch = Read-EventBatch -LogPath $LogPath -Offset $offset

    # Resolve the sink Context once per tick (fresh settings each cycle so an
    # operator's config edit takes effect without a restart). Sinks read the
    # section they need: webhooks → Settings.events.webhooks, mothership →
    # Settings.mothership + Settings.events.mothership.
    $context = @{ BotRoot = $BotRoot; Settings = (_Get-MergedSettingsSafe -BotRoot $BotRoot) }

    $dispatchedTotal = 0
    foreach ($evt in $batch.events) {
        # Invoke-EventSinks is non-aborting and never throws, but guard anyway
        # so a single event can never wedge the cursor.
        try {
            $r = Invoke-EventSinks -Event $evt -Registry $Registry -BotRoot $BotRoot -Context $context
            $dispatchedTotal += [int]$r.dispatched
        } catch {
            $null = $_
        }
    }

    # Advance the cursor only after dispatch (at-least-once).
    Save-EventCursor -BotRoot $BotRoot -Offset $batch.position

    return @{
        processed  = @($batch.events).Count
        dispatched = $dispatchedTotal
        position   = $batch.position
    }
}

# ─── Runspace lifecycle (mirrors ControlPlaneClient) ────────────────────────

function _Test-EventConsumerEnabled {
    # Master kill-switch: events.enabled. Defaults to on when settings are
    # unavailable (e.g. isolated unit tests import only Dotbot.Events).
    param([Parameter(Mandatory)] [string]$BotRoot)

    if (-not (Get-Command Get-MergedSettings -ErrorAction SilentlyContinue)) { return $true }
    try {
        $settings = Get-MergedSettings -BotRoot $BotRoot
        if ($null -ne $settings -and $null -ne $settings.events -and $settings.events.enabled -eq $false) {
            return $false
        }
    } catch {
        $null = $_
    }
    return $true
}

function Start-EventConsumer {
    <#
    .SYNOPSIS
    Start the background consumer on a dedicated runspace. Returns a handle for
    Stop-EventConsumer, or $null when the bus is disabled.

    .DESCRIPTION
    Discovers sinks once, seeds the cursor to EOF on first-ever start, then
    loops Invoke-EventConsumerTick on the runspace until the stop flag is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [double]$IntervalSeconds = 2
    )

    if (-not (_Test-EventConsumerEnabled -BotRoot $BotRoot)) {
        return $null
    }

    # Discover sinks once in the parent (fail-loud happens here at startup).
    $registry = @(Get-SinkRegistry -BotRoot $BotRoot)

    # Seed the cursor so we never replay history to sinks on first-ever start.
    Initialize-EventConsumerCursor -BotRoot $BotRoot | Out-Null

    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Dotbot.Events.psd1'
    # Dotbot.Settings sits alongside Dotbot.Events under Modules/. Import it in
    # the loop so Invoke-EventConsumerTick can resolve the sink Context's
    # `events` config each cycle.
    $settingsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) (Join-Path 'Dotbot.Settings' 'Dotbot.Settings.psd1')

    # Single-element bool array passed by reference into the runspace as the
    # cooperative stop signal.
    $stopFlag = [bool[]]::new(1)

    $loop = {
        param([string]$BotRoot, $Registry, [double]$IntervalSeconds, [string]$ModulePath, [string]$SettingsPath, [bool[]]$StopFlag)

        Import-Module $ModulePath -DisableNameChecking -Global -ErrorAction SilentlyContinue
        Import-Module $SettingsPath -DisableNameChecking -Global -ErrorAction SilentlyContinue

        while (-not $StopFlag[0]) {
            try {
                Invoke-EventConsumerTick -BotRoot $BotRoot -Registry $Registry | Out-Null
            } catch {
                $null = $_
            }
            # Chunked sleep so a stop request is honoured promptly.
            $slept = 0.0
            while ($slept -lt $IntervalSeconds -and -not $StopFlag[0]) {
                Start-Sleep -Milliseconds 200
                $slept += 0.2
            }
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $null = $ps.AddScript($loop)
    $null = $ps.AddArgument($BotRoot)
    $null = $ps.AddArgument($registry)
    $null = $ps.AddArgument($IntervalSeconds)
    $null = $ps.AddArgument($modulePath)
    $null = $ps.AddArgument($settingsPath)
    $null = $ps.AddArgument($stopFlag)
    $async = $ps.BeginInvoke()

    return @{
        enabled    = $true
        stop_flag  = $stopFlag
        ps         = $ps
        runspace   = $runspace
        async      = $async
        registry   = $registry
        bot_root   = $BotRoot
    }
}

function Stop-EventConsumer {
    <#
    .SYNOPSIS
    Signal the consumer loop to stop and dispose its runspace. Idempotent.
    #>
    [CmdletBinding()]
    param($Consumer)

    if ($null -eq $Consumer) { return }

    # Use `$null -ne` explicitly: a [bool[]] of length 1 evaluates to its single
    # element in a boolean context, so `if ($Consumer.stop_flag)` would be
    # $false when the flag is still down and never set it.
    try { if ($null -ne $Consumer.stop_flag) { $Consumer.stop_flag[0] = $true } } catch { $null = $_ }
    try { if ($null -ne $Consumer.ps)        { $Consumer.ps.Stop(); $Consumer.ps.Dispose() } }        catch { $null = $_ }
    try { if ($null -ne $Consumer.runspace)  { $Consumer.runspace.Close(); $Consumer.runspace.Dispose() } } catch { $null = $_ }
}

Export-ModuleMember -Function @(
    'Get-EventCursorPath'
    'Read-EventCursor'
    'Save-EventCursor'
    'Initialize-EventConsumerCursor'
    'Read-EventBatch'
    'Invoke-EventConsumerTick'
    'Start-EventConsumer'
    'Stop-EventConsumer'
)
