<#
.SYNOPSIS
Activity log (single source of state-change events).

Every state-mutating runtime call writes one JSON line to
<BotRoot>/.control/activity.jsonl. Writes are append-only and atomic per
line — the runtime is the sole writer, and a per-process SemaphoreSlim
guards the writer so two listener threads on the same runtime can't
interleave bytes.

Event shape:
{
  "timestamp":   "2026-05-18T10:00:00Z",
  "project_id":  "p_AbCd1234",
  "type":        "task_created" | "task_status_changed" | ...
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
$script:DotbotActivityLogEventTypes = @(
    'task_created'
    'task_updated'
    'task_status_changed'
    'workflow_run_started'
    'workflow_run_completed'
    'workflow_run_failed'
    'workflow_run_cancelled'
    'hook_failed'
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
        [string]$Reason
    )

    $event = [ordered]@{
        timestamp  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        project_id = Get-DotbotProjectId -BotRoot $BotRoot
        type       = $Type
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
            $line + [System.Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    } finally {
        [void]$lock.Release()
    }
}

Export-ModuleMember -Function @(
    'Write-ActivityEvent'
    'Get-ActivityLogPath'
    'Get-DotbotProjectId'
    'Get-ActivityLogEventTypes'
)
