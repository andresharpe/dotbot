<#
.SYNOPSIS
Activity log (single source of state-change events).

Every state-mutating runtime call writes one JSON line to
<BotRoot>/.control/activity.jsonl. Writes are append-only and atomic per
line — the runtime is the sole writer, and a per-process SemaphoreSlim
guards the writer so two listener threads on the same runtime can't
interleave bytes.

Event shape (dotted type so each line is a bus event matching task.* /
workflow.* sink globs):
{
  "id":          "evt_xxxxxxxx",
  "type":        "task.created" | "task.status_changed" | "workflow.run_started" | ...
  "timestamp":   "2026-05-18T10:00:00Z",
  "source":      "runtime",
  "project_id":  "p_AbCd1234",
  "task_id":     "t_xxxxxxxx",     // when relevant
  "run_id":      "wr_xxxxxxxx",    // when relevant
  "from":        "in-progress",    // on transitions
  "to":          "done",           // on transitions
  "actor":       "ui:carlos",
  "reason":      "..."             // optional
}

Project ID: derived as a stable id at <BotRoot>/.control/project-id
(a tiny file containing 'p_' + 8 nanoid chars, created once and reused).
This avoids re-introducing a machine-wide registry.
#>

# Per-process activity-log lock. Stored on the AppDomain because this module
# loads into per-request runspaces (HttpServer dispatches each handler into
# its own runspace), and module-script scope is per-runspace. Without the
# AppDomain shim, two concurrent handlers in two runspaces would hold two
# different SemaphoreSlim instances and could interleave bytes in
# activity.jsonl.
$script:DotbotActivityLogLockKey  = 'Dotbot.Runtime.ActivityLogLock'
$script:DotbotProjectIdCache      = @{}  # BotRoot → project_id  (per-runspace is fine: cache is read-mostly)

function _Get-ActivityLogLock {
    $lock = [System.AppDomain]::CurrentDomain.GetData($script:DotbotActivityLogLockKey)
    if ($null -eq $lock) {
        $lock = [System.Threading.SemaphoreSlim]::new(1, 1)
        [System.AppDomain]::CurrentDomain.SetData($script:DotbotActivityLogLockKey, $lock)
    }
    return $lock
}

# ---------------------------------------------------------------------------
# Event-type registry (extensible)
#
# Publish-DotBotEvent validates a dotted event type (e.g. 'task.completed')
# against this registry. Entries are wildcard patterns, so a family like
# 'task.*' registers a whole namespace. An unregistered type is LOGGED and
# STILL DELIVERED — never rejected — so new families (e.g. 'nudge.*') need no
# publisher change; they just append to the registry when their producer loads.
#
# Stored on the AppDomain (like the writer lock) so a registration made in one
# runspace is visible to publishers in the per-request runspaces.
# ---------------------------------------------------------------------------
$script:DotbotEventTypeRegistryKey = 'Dotbot.Runtime.EventTypeRegistry'
$script:DotbotDefaultEventTypes    = @(
    'task.*'
    'workflow.*'
)

function _Get-EventTypeRegistry {
    $registry = [System.AppDomain]::CurrentDomain.GetData($script:DotbotEventTypeRegistryKey)
    if ($null -eq $registry) {
        $registry = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $script:DotbotDefaultEventTypes) { $registry.Add($t) }
        [System.AppDomain]::CurrentDomain.SetData($script:DotbotEventTypeRegistryKey, $registry)
    }
    # Unary comma prevents PowerShell from unrolling the List on return, so
    # callers get the live List object (needed for .Add / .ToArray), not its
    # enumerated elements.
    return ,$registry
}

function Register-DotBotEventType {
    <#
    .SYNOPSIS
    Register an event type (or a wildcard family such as 'nudge.*') so that
    Publish-DotBotEvent treats it as a known type.

    .DESCRIPTION
    Idempotent: registering the same pattern twice is a no-op. Registration is
    process-wide (AppDomain-backed) so producers loaded in any runspace share
    one registry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Type)

    $registry = _Get-EventTypeRegistry
    if (-not ($registry -contains $Type)) {
        $registry.Add($Type)
    }
}

function Get-DotBotEventTypeRegistry {
    <#
    .SYNOPSIS
    Return the current event-type registry (array of patterns). For tests and
    diagnostics.
    #>
    return ,@((_Get-EventTypeRegistry).ToArray())
}

function Test-DotBotEventTypeRegistered {
    <#
    .SYNOPSIS
    Return $true when the given concrete type matches any registered pattern.

    .DESCRIPTION
    Registry entries are treated as wildcard patterns, so 'task.completed'
    matches the registered family 'task.*', and an exactly-registered concrete
    type matches itself.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Type)

    foreach ($pattern in (_Get-EventTypeRegistry)) {
        if ($Type -like $pattern) { return $true }
    }
    return $false
}

$script:DotbotActivityLogEventTypes = @(
    'task.created'
    'task.updated'
    'task.status_changed'
    'workflow.run_started'
    'workflow.run_completed'
    'workflow.run_failed'
    'workflow.run_cancelled'
    'hook.failed'
)

function Get-ActivityLogPath {
    <#
    .SYNOPSIS
    Resolve <BotRoot>/.control/activity.jsonl. Does not create the file.
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path $BotRoot (Join-Path '.control' 'activity.jsonl')
}

function _Get-ProjectIdFilePath {
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path $BotRoot (Join-Path '.control' 'project-id')
}

function Get-DotbotProjectId {
    <#
    .SYNOPSIS
    Get (or create + persist) the per-project ID used in activity-log lines.

    .DESCRIPTION
    Returns 'p_' + 8 chars [A-Za-z0-9]. Created on first call and persisted at
    <BotRoot>/.control/project-id; reused on every subsequent call within the
    same process and across process restarts.

    Cached per-BotRoot so repeat calls within a process don't re-touch disk.
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)

    if ($script:DotbotProjectIdCache.ContainsKey($BotRoot)) {
        return $script:DotbotProjectIdCache[$BotRoot]
    }

    $path = _Get-ProjectIdFilePath -BotRoot $BotRoot
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()
            if ($existing -cmatch '^p_[A-Za-z0-9]{8}$') {
                $script:DotbotProjectIdCache[$BotRoot] = $existing
                return $existing
            }
        } catch {
            # Fall through and rewrite below.
        }
    }

    # Pull New-DotbotNanoId from Dotbot.Task's IdGen. The Runtime module
    # imports Dotbot.Task globally, so the function is in scope.
    if (-not (Get-Command New-DotbotNanoId -ErrorAction SilentlyContinue)) {
        throw "Get-DotbotProjectId requires New-DotbotNanoId (Dotbot.Task IdGen) — module not loaded."
    }
    $newId = 'p_' + (New-DotbotNanoId)

    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $newId, [System.Text.UTF8Encoding]::new($false))
    $script:DotbotProjectIdCache[$BotRoot] = $newId
    return $newId
}

function Get-ActivityLogEventTypes {
    <#
    .SYNOPSIS
    Return the event-type vocabulary. Useful for tests that want to
    assert "this is a known event."
    #>
    return ,@($script:DotbotActivityLogEventTypes)
}

function _New-DotBotEventId {
    # Reuse the runtime's nanoid generator (imported globally via Dotbot.Task)
    # so event ids share the house 'prefix_ + 8 chars' convention (t_, wr_, p_).
    if (-not (Get-Command New-DotbotNanoId -ErrorAction SilentlyContinue)) {
        throw "Publish-DotBotEvent requires New-DotbotNanoId (Dotbot.Task IdGen) — module not loaded."
    }
    return 'evt_' + (New-DotbotNanoId)
}

function _Append-ActivityLogLine {
    <#
    .SYNOPSIS
    Append one already-serialized JSON line to <BotRoot>/.control/activity.jsonl
    under the process-wide writer lock. Shared by Write-ActivityEvent and
    Publish-DotBotEvent so both use the SAME SemaphoreSlim and can never
    interleave bytes with each other.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$Line
    )

    $path = Get-ActivityLogPath -BotRoot $BotRoot
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $lock = _Get-ActivityLogLock
    $lock.Wait()
    try {
        # AppendAllText opens / appends / closes per call. On POSIX this is
        # atomic for sub-PIPE_BUF writes (any line we produce here). On NTFS
        # it's atomic for sub-4KB writes. The +newline keeps lines separated.
        [System.IO.File]::AppendAllText(
            $path,
            $Line + [System.Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    } finally {
        [void]$lock.Release()
    }
}

function Publish-DotBotEvent {
    <#
    .SYNOPSIS
    Publish a typed event onto the event bus.

    .DESCRIPTION
    Stamps a well-formed envelope — id, type, timestamp, source, data, plus the
    project id and actor — and appends it as one JSON line to
    <BotRoot>/.control/activity.jsonl. Publishing to the activity log means the
    /api/activity/tail byte-cursor endpoint carries bus events to the browser
    with no new transport.

    The Type is validated against the extensible event-type registry. An
    UNREGISTERED type is logged and STILL DELIVERED (never rejected), so new
    event families need no change to this publisher.

    .PARAMETER Type
    The dotted event type, e.g. 'task.completed' or 'workflow.run_failed'.

    .PARAMETER Source
    Where the event originated, e.g. 'runtime'.

    .PARAMETER Data
    Arbitrary event payload; serialized as the envelope's nested 'data' object.

    .OUTPUTS
    The envelope hashtable that was written (so callers/tests can inspect the id).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$Type,
        [Parameter(Mandatory)] [string]$Source,
        [hashtable]$Data,
        [string]$Actor = 'system'
    )

    if (-not (Test-DotBotEventTypeRegistered -Type $Type)) {
        # Logged, not rejected — the registry is extensible by design. Debug
        # level: Write-BotLog only mirrors Info+ into activity.jsonl, so this
        # note never pollutes the bus itself. Guarded so the module stays
        # usable when Dotbot.Logging isn't loaded.
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Publish-DotBotEvent: unregistered event type '$Type' — delivering anyway."
        }
    }

    $envelope = [ordered]@{
        id         = _New-DotBotEventId
        type       = $Type
        timestamp  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source     = $Source
        data       = if ($null -ne $Data) { $Data } else { @{} }
        project_id = Get-DotbotProjectId -BotRoot $BotRoot
        actor      = $Actor
    }

    $line = $envelope | ConvertTo-Json -Depth 10 -Compress
    _Append-ActivityLogLine -BotRoot $BotRoot -Line $line

    return $envelope
}

function Write-ActivityEvent {
    <#
    .SYNOPSIS
    Append a single activity-log event line to <BotRoot>/.control/activity.jsonl.

    .DESCRIPTION
    One JSON line per call. Stamps a UTC RFC3339-Z timestamp and the
    project-id automatically; the caller supplies the rest.

    The append is guarded by a process-wide SemaphoreSlim so two HTTP handler
    threads can't interleave bytes. The runtime is the sole writer; external
    processes appending to the same file would race the lock — out of scope.

    .PARAMETER Type
    The event type. Must be one of the documented vocabulary; other strings
    throw so a typo doesn't quietly produce events the UI consumer can't
    filter on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateScript({ $script:DotbotActivityLogEventTypes -contains $_ })]
        [string]$Type,

        [string]$TaskId,
        [string]$RunId,
        [string]$From,
        [string]$To,
        [string]$Actor = 'system',
        [string]$Reason,
        [string]$Source = 'runtime'
    )

    $event = [ordered]@{
        id         = _New-DotBotEventId
        type       = $Type
        timestamp  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source     = $Source
        project_id = Get-DotbotProjectId -BotRoot $BotRoot
    }
    if ($TaskId) { $event['task_id'] = $TaskId }
    if ($RunId)  { $event['run_id']  = $RunId }
    if ($From)   { $event['from']    = $From }
    if ($To)     { $event['to']      = $To }
    $event['actor'] = $Actor
    if ($Reason) { $event['reason'] = $Reason }

    # Compact one-line JSON. -Compress strips the pretty-print spacing so
    # one entry = one physical line, which is what the UI's FileWatcher
    # consumer assumes.
    $line = $event | ConvertTo-Json -Depth 6 -Compress
    _Append-ActivityLogLine -BotRoot $BotRoot -Line $line
}

Export-ModuleMember -Function @(
    'Write-ActivityEvent'
    'Publish-DotBotEvent'
    'Register-DotBotEventType'
    'Get-DotBotEventTypeRegistry'
    'Test-DotBotEventTypeRegistered'
    'Get-ActivityLogPath'
    'Get-DotbotProjectId'
    'Get-ActivityLogEventTypes'
)
