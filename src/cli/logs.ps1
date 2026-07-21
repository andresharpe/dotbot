#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot logs — surface recent activity-log events, or the last crash summary.

.DESCRIPTION
    Reads <BotRoot>/.control/activity.jsonl and prints the last N events in a
    human-readable format so an operator can see what happened after the run's
    terminal window has closed.

      dotbot logs                 last 50 events from activity.jsonl
      dotbot logs --tail 200      last 200 events
      dotbot logs --last          the crash summary written on the last fatal exit
      dotbot logs --follow        tail the activity log in real time (Ctrl+C stops)

    activity.jsonl is a mixed-shape JSONL file: structured-logging events carry a
    `message`/`msg` field, while typed state-change events carry `from`/`to`/
    `reason` instead. The formatter tolerates both.

    Output uses the standard CLI theme helpers from Platform-Functions.psm1
    (AGENTS.md terminal-output rule).

    Exit codes:
      0  success (including --last when no crash has been recorded)
      1  no .bot/ directory, or the activity log is missing / unreadable
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 100000)]
    [int]$Tail = 50,

    [switch]$Last,

    [switch]$Follow,

    [ValidateRange(100, 60000)]
    [int]$PollIntervalMs = 1000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Import-Module (Join-Path $PSScriptRoot 'Platform-Functions.psm1') -Force

function Find-BotRoot {
    # Walk up from the current directory to the nearest .bot/, stopping at the
    # git-repo boundary so `dotbot logs` never escapes the project it is run in
    # (mirrors Find-DotbotProjectBotDir in bin/dotbot.ps1).
    $cur = (Get-Location).Path
    while ($cur) {
        $candidate = Join-Path $cur '.bot'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        if (Test-Path -LiteralPath (Join-Path $cur '.git')) { return $null }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}

function Read-ActivityLine {
    <#
    .SYNOPSIS
    Read every non-empty line of a JSONL file. FileShare::ReadWrite because the
    runtime may hold the file open for appends while we read.
    #>
    param([Parameter(Mandatory)] [string]$Path)

    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return @($text -split "`n" | Where-Object { $_.Trim() })
}

function Format-ActivityEvent {
    <#
    .SYNOPSIS
    Turn one parsed activity event into a { Type; Line } pair. Handles both the
    logging shape (message/msg) and the typed state-change shape (from/to/reason).
    #>
    param([Parameter(Mandatory)] [object]$Event)

    $ts = ''
    if ($Event.PSObject.Properties['timestamp'] -and $Event.timestamp) {
        try { $ts = ([datetime]$Event.timestamp).ToLocalTime().ToString('HH:mm:ss') }
        catch { $ts = [string]$Event.timestamp }
    }

    $type = if ($Event.PSObject.Properties['type'] -and $Event.type) { [string]$Event.type } else { 'event' }

    $text = $null
    if ($Event.PSObject.Properties['message'] -and $Event.message) {
        $text = [string]$Event.message
    } elseif ($Event.PSObject.Properties['msg'] -and $Event.msg) {
        $text = [string]$Event.msg
    } elseif ($Event.PSObject.Properties['from'] -and $Event.PSObject.Properties['to']) {
        $text = "$($Event.from) -> $($Event.to)"
    }
    if ($Event.PSObject.Properties['reason'] -and $Event.reason) {
        $text = if ($text) { "$text ($($Event.reason))" } else { [string]$Event.reason }
    }
    if (-not $text) { $text = '' }

    $phase = if ($Event.PSObject.Properties['phase'] -and $Event.phase) { "[$($Event.phase)] " } else { '' }

    return [pscustomobject]@{
        Type = $type
        Line = ("{0}  {1}{2}  {3}" -f $ts, $phase, $type, $text).TrimEnd()
    }
}

function Write-ActivityEventLine {
    <#
    .SYNOPSIS
    Print one activity event, colour-coded by level via the theme helpers.
    #>
    param([Parameter(Mandatory)] [object]$Event)

    $formatted = Format-ActivityEvent -Event $Event
    $t = $formatted.Type.ToLowerInvariant()
    if ($t -in @('error', 'fatal', 'workflow_run_failed', 'hook_failed')) {
        Write-DotbotError $formatted.Line
    } elseif ($t -in @('warn', 'warning', 'workflow_run_cancelled')) {
        Write-DotbotWarning $formatted.Line
    } else {
        Write-DotbotCommand $formatted.Line
    }
}

$botRoot = Find-BotRoot
if (-not $botRoot) {
    Write-DotbotError "Could not find a .bot/ directory in this or any parent path."
    Write-DotbotCommand "Run 'dotbot init' first."
    exit 1
}

$controlDir = Join-Path $botRoot '.control'

# --- Crash summary mode (--last) ---
if ($Last) {
    $crashPath = Join-Path $controlDir 'last-crash.json'
    if (-not (Test-Path -LiteralPath $crashPath)) {
        Write-DotbotSection "LAST CRASH"
        Write-DotbotLabel "Status:" "No crash recorded" -ValueType Success
        Write-BlankLine
        Write-DotbotCommand "Nothing has crashed since .bot/.control/last-crash.json was last cleared."
        exit 0
    }

    try {
        $crash = Get-Content -LiteralPath $crashPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-DotbotError "Could not read last-crash.json: $($_.Exception.Message)"
        exit 1
    }

    Write-DotbotSection "LAST CRASH"
    Write-DotbotLabel "Time:"   ([string]$crash.timestamp)
    Write-DotbotLabel "Reason:" ([string]$crash.exit_reason) -ValueType Error
    if ($crash.process_id) { Write-DotbotLabel "Process:" ([string]$crash.process_id) }
    if ($crash.run_id)     { Write-DotbotLabel "Run:"     ([string]$crash.run_id) }
    if ($crash.last_task -and ($crash.last_task.id -or $crash.last_task.name)) {
        $taskLabel = @($crash.last_task.name, $crash.last_task.id, $crash.last_task.status |
            Where-Object { $_ }) -join ' · '
        Write-DotbotLabel "Last task:" $taskLabel
    }
    Write-BlankLine

    $events = @($crash.last_events)
    if ($events.Count -gt 0) {
        Write-DotbotSection "LAST EVENTS"
        foreach ($ev in $events) { Write-ActivityEventLine -Event $ev }
        Write-BlankLine
    }
    exit 0
}

# --- Activity log (tail / follow) ---
$activityPath = Join-Path $controlDir 'activity.jsonl'
if (-not (Test-Path -LiteralPath $activityPath)) {
    Write-DotbotSection "LOGS"
    Write-DotbotLabel "Status:" "No activity log yet" -ValueType Warning
    Write-BlankLine
    Write-DotbotCommand "Nothing has been logged to .bot/.control/activity.jsonl yet."
    exit 1
}

Write-DotbotSection "LOGS"

try {
    $lines = Read-ActivityLine -Path $activityPath
} catch {
    Write-DotbotError "Could not read activity log: $($_.Exception.Message)"
    exit 1
}

$total = $lines.Count
$startIdx = [Math]::Max(0, $total - $Tail)
for ($i = $startIdx; $i -lt $total; $i++) {
    try { Write-ActivityEventLine -Event ($lines[$i] | ConvertFrom-Json) } catch { $null = $_ }
}
$position = $total

if (-not $Follow) {
    Write-BlankLine
    exit 0
}

# --- Follow mode: poll for appends (mirrors the watch loop in workflow-run.ps1) ---
Write-BlankLine
Write-DotbotCommand "Following activity log — press Ctrl+C to stop."
Write-BlankLine

$script:DotbotLogsStopRequested = $false
try {
    [Console]::CancelKeyPress.Add({
        param($sender, $eventArgs)
        $eventArgs.Cancel = $true
        $script:DotbotLogsStopRequested = $true
    })
} catch {
    $null = $_
}

while (-not $script:DotbotLogsStopRequested) {
    Start-Sleep -Milliseconds $PollIntervalMs
    try {
        $lines = Read-ActivityLine -Path $activityPath
    } catch {
        continue
    }
    $total = $lines.Count
    # A rotated / truncated log resets our cursor so we don't skip its new tail.
    if ($total -lt $position) { $position = 0 }
    if ($total -gt $position) {
        for ($i = $position; $i -lt $total; $i++) {
            try { Write-ActivityEventLine -Event ($lines[$i] | ConvertFrom-Json) } catch { $null = $_ }
        }
        $position = $total
    }
}

Write-BlankLine
exit 0
