#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Dotbot.Events sink-discovery tests.
.DESCRIPTION
    Covers the discovery surface of Dotbot.Events (parity with the Dotbot.Hook
    engine):

      - Folder-per-sink discovery: metadata.json + script.ps1, sorted by folder
        name, records carry the expected shape.
      - Event routing: Get-SinksForEvent matches a concrete dotted event type
        against each sink's subscribed_events glob patterns.
      - Fail-loud validation: malformed sink metadata throws rather than being
        silently skipped, so one bad sink among valid ones fails the whole
        registry scan at startup.

    No installed dotbot needed (module is imported directly from src/).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Dotbot.Events — Sink Discovery" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Events/Dotbot.Events.psd1") -Force -DisableNameChecking -Global

# Small helper: assert a scriptblock throws and (optionally) message matches a pattern.
function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$Pattern
    )
    $threw = $false
    $msg = ''
    try { & $Action } catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) {
        Write-TestResult -Name $Name -Status Fail -Message "Expected an exception, got none."
        return
    }
    if ($Pattern -and ($msg -notmatch $Pattern)) {
        Write-TestResult -Name $Name -Status Fail -Message "Exception '$msg' did not match pattern '$Pattern'."
        return
    }
    Write-TestResult -Name $Name -Status Pass
}

# ───────────────────────────────────────────────────────────────────────────
# Fixture helpers
# ───────────────────────────────────────────────────────────────────────────

function New-SinksRoot {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-sinks-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-SinkFixture {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Name,
        [object]$Metadata,          # hashtable to serialize, or a raw string for malformed-JSON cases
        [switch]$NoMetadata,
        [switch]$NoScript,
        [string]$RawMetadata,
        [string]$ScriptBody         # override the default Invoke-Sink body
    )
    $sinkDir = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $sinkDir -Force | Out-Null

    if (-not $NoMetadata) {
        $metaPath = Join-Path $sinkDir 'metadata.json'
        if ($PSBoundParameters.ContainsKey('RawMetadata')) {
            Set-Content -LiteralPath $metaPath -Value $RawMetadata -Encoding utf8NoBOM
        } else {
            ($Metadata | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $metaPath -Encoding utf8NoBOM
        }
    }
    if (-not $NoScript) {
        $scriptPath = Join-Path $sinkDir 'script.ps1'
        $body = if ($PSBoundParameters.ContainsKey('ScriptBody')) {
            $ScriptBody
        } else {
            "function Invoke-Sink { param(`$Event) }`nExport-ModuleMember -Function Invoke-Sink"
        }
        Set-Content -LiteralPath $scriptPath -Value $body -Encoding utf8NoBOM
    }
    return $sinkDir
}

function Add-EventLine {
    # Append one activity.jsonl event line (hand-written so this test needn't
    # import Dotbot.Runtime/Dotbot.Task). data.marker points a sink at its
    # output file.
    param(
        [Parameter(Mandatory)] [string]$LogPath,
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$Type,
        [string]$Marker
    )
    $line = @{ id = $Id; type = $Type; source = 'runtime'; data = @{ marker = $Marker } } | ConvertTo-Json -Compress
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8NoBOM
}

# ═══════════════════════════════════════════════════════════════════════════
# Happy-path discovery
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Discovery" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$root = New-SinksRoot
try {
    New-SinkFixture -Root $root -Name 'alpha' -Metadata @{ name = 'alpha'; description = 'A sink'; subscribed_events = @('task.*'); max_duration = 10 } | Out-Null
    New-SinkFixture -Root $root -Name 'zeta'  -Metadata @{ name = 'zeta';  subscribed_events = @('workflow.run_completed', 'task.created'); max_duration = 5 } | Out-Null

    $registry = @(Get-SinkRegistry -SinksDir $root)
    Assert-Equal -Name "registry discovers both sinks" -Expected 2 -Actual $registry.Count
    Assert-Equal -Name "registry is sorted by folder name (alpha first)" -Expected 'alpha' -Actual $registry[0].name
    Assert-Equal -Name "registry is sorted by folder name (zeta second)" -Expected 'zeta'  -Actual $registry[1].name

    $alpha = $registry[0]
    Assert-Equal -Name "alpha carries description"           -Expected 'A sink' -Actual $alpha.description
    Assert-Equal -Name "alpha carries max_duration as int"   -Expected 10       -Actual $alpha.max_duration
    Assert-True  -Name "alpha subscribed_events has task.*"   -Condition ($alpha.subscribed_events -contains 'task.*')
    Assert-True  -Name "alpha record points at its script.ps1" -Condition (Test-Path -LiteralPath $alpha.script_path)
    Assert-True  -Name "alpha record points at its metadata.json" -Condition (Test-Path -LiteralPath $alpha.metadata_path)

    # ── Event routing (glob match) ──
    $forTaskCreated = @(Get-SinksForEvent -Registry $registry -EventType 'task.created')
    Assert-Equal -Name "task.created routes to both (alpha via task.*, zeta via exact)" -Expected 2 -Actual $forTaskCreated.Count

    $forTaskUpdated = @(Get-SinksForEvent -Registry $registry -EventType 'task.updated')
    Assert-Equal -Name "task.updated routes to alpha only (task.* glob)" -Expected 1 -Actual $forTaskUpdated.Count
    Assert-Equal -Name "task.updated matched sink is alpha" -Expected 'alpha' -Actual $forTaskUpdated[0].name

    $forRunCompleted = @(Get-SinksForEvent -Registry $registry -EventType 'workflow.run_completed')
    Assert-Equal -Name "workflow.run_completed routes to zeta only" -Expected 1 -Actual $forRunCompleted.Count
    Assert-Equal -Name "workflow.run_completed matched sink is zeta" -Expected 'zeta' -Actual $forRunCompleted[0].name

    $forDecision = @(Get-SinksForEvent -Registry $registry -EventType 'decision.created')
    Assert-Equal -Name "unsubscribed event routes to no sinks" -Expected 0 -Actual $forDecision.Count
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# ── Empty / missing sinks dir is not an error ──
$missing = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-sinks-none-" + [guid]::NewGuid().ToString('N').Substring(0,8))
Assert-Equal -Name "missing sinks dir yields empty registry (no throw)" -Expected 0 -Actual (@(Get-SinkRegistry -SinksDir $missing)).Count

# ═══════════════════════════════════════════════════════════════════════════
# Fail-loud validation
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Fail-loud validation" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bad = New-SinksRoot
try {
    $d = New-SinkFixture -Root $bad -Name 'no-meta' -NoMetadata
    Assert-Throws -Name "missing metadata.json throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'missing metadata.json'

    $d = New-SinkFixture -Root $bad -Name 'no-script' -Metadata @{ name = 'x'; subscribed_events = @('task.*'); max_duration = 5 } -NoScript
    Assert-Throws -Name "missing script.ps1 throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'missing script.ps1'

    $d = New-SinkFixture -Root $bad -Name 'bad-json' -RawMetadata '{ not valid json ]'
    Assert-Throws -Name "invalid JSON throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'Invalid metadata.json'

    $d = New-SinkFixture -Root $bad -Name 'no-max' -Metadata @{ name = 'x'; subscribed_events = @('task.*') }
    Assert-Throws -Name "missing required field throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern "missing required field 'max_duration'"

    $d = New-SinkFixture -Root $bad -Name 'empty-events' -Metadata @{ name = 'x'; subscribed_events = @(); max_duration = 5 }
    Assert-Throws -Name "empty subscribed_events throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'empty subscribed_events'

    $d = New-SinkFixture -Root $bad -Name 'blank-event' -Metadata @{ name = 'x'; subscribed_events = @('task.*', ''); max_duration = 5 }
    Assert-Throws -Name "blank subscribed_events entry throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'blank entry in subscribed_events'

    $d = New-SinkFixture -Root $bad -Name 'zero-dur' -Metadata @{ name = 'x'; subscribed_events = @('task.*'); max_duration = 0 }
    Assert-Throws -Name "non-positive max_duration throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'non-positive max_duration'
} finally {
    Remove-Item -Recurse -Force $bad -ErrorAction SilentlyContinue
}

# ── One malformed sink among valid ones fails the whole registry scan ──
$mixed = New-SinksRoot
try {
    New-SinkFixture -Root $mixed -Name 'good' -Metadata @{ name = 'good'; subscribed_events = @('task.*'); max_duration = 5 } | Out-Null
    New-SinkFixture -Root $mixed -Name 'broken' -Metadata @{ name = 'broken'; subscribed_events = @('task.*') } | Out-Null  # missing max_duration
    Assert-Throws -Name "Get-SinkRegistry fails loudly when any sink is malformed" -Action { Get-SinkRegistry -SinksDir $mixed } -Pattern "missing required field"
} finally {
    Remove-Item -Recurse -Force $mixed -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# Dispatch (time-boxed child runspace, non-aborting)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Dispatch" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$disp = New-SinksRoot
try {
    # A sink that records the event it received, to prove the payload reaches
    # the sink runspace (type + nested data round-trip).
    $markerBody = @'
function Invoke-Sink {
    param($Event)
    Set-Content -LiteralPath $Event.data.marker -Value $Event.type -Encoding utf8NoBOM
}
Export-ModuleMember -Function Invoke-Sink
'@
    $markerSink = New-SinkFixture -Root $disp -Name 'marker' -Metadata @{ name = 'marker'; subscribed_events = @('task.*'); max_duration = 10 } -ScriptBody $markerBody
    $markerRec  = Read-SinkMetadata -SinkDir $markerSink

    $markerFile = Join-Path $disp 'marker.out'
    $evt = @{ type = 'task.created'; data = @{ marker = $markerFile } }
    $res = Invoke-SingleSink -Sink $markerRec -Event $evt
    Assert-True  -Name "successful sink reports success"        -Condition ([bool]$res.success)
    Assert-True  -Name "successful sink is not timed_out"        -Condition (-not $res.timed_out)
    Assert-True  -Name "sink actually ran (marker file written)" -Condition (Test-Path -LiteralPath $markerFile)
    Assert-Equal -Name "sink received the event payload (type via data.marker)" -Expected 'task.created' -Actual (Get-Content -LiteralPath $markerFile -Raw).Trim()

    # A sink that throws → captured as failure, never rethrown.
    $throwSink = New-SinkFixture -Root $disp -Name 'boom' -Metadata @{ name = 'boom'; subscribed_events = @('task.*'); max_duration = 10 } -ScriptBody "function Invoke-Sink { param(`$Event) throw 'kaboom' }`nExport-ModuleMember -Function Invoke-Sink"
    $throwRec  = Read-SinkMetadata -SinkDir $throwSink
    $throwRes  = Invoke-SingleSink -Sink $throwRec -Event $evt
    Assert-True -Name "throwing sink reports failure (not rethrown)" -Condition (-not [bool]$throwRes.success)
    Assert-True -Name "throwing sink message carries the error"      -Condition ($throwRes.message -match 'kaboom')

    # A slow sink → forcibly stopped at max_duration, marked timed_out.
    $slowSink = New-SinkFixture -Root $disp -Name 'slow' -Metadata @{ name = 'slow'; subscribed_events = @('task.*'); max_duration = 1 } -ScriptBody "function Invoke-Sink { param(`$Event) Start-Sleep -Seconds 5 }`nExport-ModuleMember -Function Invoke-Sink"
    $slowRec  = Read-SinkMetadata -SinkDir $slowSink
    $slowRes  = Invoke-SingleSink -Sink $slowRec -Event $evt
    Assert-True -Name "slow sink is marked timed_out"     -Condition ([bool]$slowRes.timed_out)
    Assert-True -Name "slow sink reports failure"          -Condition (-not [bool]$slowRes.success)
    Assert-True -Name "slow sink stopped near max_duration (< 4s)" -Condition ($slowRes.duration.TotalSeconds -lt 4)
} finally {
    Remove-Item -Recurse -Force $disp -ErrorAction SilentlyContinue
}

# ── Non-aborting fan-out: a failing sink must not stop the others ──
# 'aaa-boom' sorts first and throws; 'bbb-good' sorts second and writes a
# marker. If dispatch aborted on failure, the marker would never appear.
$fan = New-SinksRoot
try {
    New-SinkFixture -Root $fan -Name 'aaa-boom' -Metadata @{ name = 'aaa-boom'; subscribed_events = @('task.*'); max_duration = 10 } -ScriptBody "function Invoke-Sink { param(`$Event) throw 'first sink fails' }`nExport-ModuleMember -Function Invoke-Sink" | Out-Null
    $goodBody = @'
function Invoke-Sink {
    param($Event)
    Set-Content -LiteralPath $Event.data.marker -Value 'ran' -Encoding utf8NoBOM
}
Export-ModuleMember -Function Invoke-Sink
'@
    New-SinkFixture -Root $fan -Name 'bbb-good' -Metadata @{ name = 'bbb-good'; subscribed_events = @('task.*'); max_duration = 10 } -ScriptBody $goodBody | Out-Null

    $registry = @(Get-SinkRegistry -SinksDir $fan)
    $fanMarker = Join-Path $fan 'good.out'
    $dispatch = Invoke-EventSinks -Event @{ type = 'task.created'; data = @{ marker = $fanMarker } } -Registry $registry

    Assert-Equal -Name "Invoke-EventSinks dispatched to both matching sinks" -Expected 2 -Actual $dispatch.dispatched
    Assert-Equal -Name "Invoke-EventSinks reports event_type" -Expected 'task.created' -Actual $dispatch.event_type
    Assert-True  -Name "non-aborting: good sink ran despite the earlier sink failing" -Condition (Test-Path -LiteralPath $fanMarker)
    $boomResult = @($dispatch.results | Where-Object { $_.name -eq 'aaa-boom' })[0]
    $goodResult = @($dispatch.results | Where-Object { $_.name -eq 'bbb-good' })[0]
    Assert-True -Name "failing sink recorded as failure in results"  -Condition (-not [bool]$boomResult.success)
    Assert-True -Name "good sink recorded as success in results"     -Condition ([bool]$goodResult.success)

    # Routing: an event no sink subscribes to dispatches to nothing (no error).
    $none = Invoke-EventSinks -Event @{ type = 'decision.created'; data = @{} } -Registry $registry
    Assert-Equal -Name "unsubscribed event dispatches to zero sinks" -Expected 0 -Actual $none.dispatched
} finally {
    Remove-Item -Recurse -Force $fan -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# Consumer (byte cursor, at-least-once, replay)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Consumer" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$cbot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-consumer-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $cbot '.control') -Force | Out-Null
$csinks = New-SinksRoot
try {
    # A sink that APPENDS each received event id to a file → line count = number
    # of deliveries (lets us prove at-least-once / no-drop precisely).
    $markerBody = @'
function Invoke-Sink {
    param($Event)
    Add-Content -LiteralPath $Event.data.marker -Value $Event.id -Encoding utf8NoBOM
}
Export-ModuleMember -Function Invoke-Sink
'@
    New-SinkFixture -Root $csinks -Name 'recorder' -Metadata @{ name = 'recorder'; subscribed_events = @('task.*'); max_duration = 10 } -ScriptBody $markerBody | Out-Null
    $reg = @(Get-SinkRegistry -SinksDir $csinks)

    $log    = Join-Path $cbot '.control/activity.jsonl'
    $marker = Join-Path $cbot 'deliveries.out'

    # ── Cursor round-trip ──
    Save-EventCursor -BotRoot $cbot -Offset 42
    Assert-Equal -Name "cursor round-trips through disk" -Expected 42 -Actual (Read-EventCursor -BotRoot $cbot)

    # ── Read-EventBatch by offset ──
    Add-EventLine -LogPath $log -Id 'evt_1' -Type 'task.created'         -Marker $marker
    Add-EventLine -LogPath $log -Id 'evt_2' -Type 'task.updated'         -Marker $marker
    Add-EventLine -LogPath $log -Id 'evt_3' -Type 'workflow.run_started' -Marker $marker

    $b0 = Read-EventBatch -LogPath $log -Offset 0
    Assert-Equal -Name "batch from 0 reads all 3 lines" -Expected 3 -Actual (@($b0.events).Count)
    Assert-True  -Name "batch position advances to EOF" -Condition ($b0.position -gt 0)

    $b1 = Read-EventBatch -LogPath $log -Offset $b0.position
    Assert-Equal -Name "batch from EOF reads nothing" -Expected 0 -Actual (@($b1.events).Count)
    Assert-Equal -Name "batch from EOF keeps position" -Expected $b0.position -Actual $b1.position

    # ── Tick: dispatch task.* only, advance cursor ──
    Save-EventCursor -BotRoot $cbot -Offset 0
    $t1 = Invoke-EventConsumerTick -BotRoot $cbot -Registry $reg -LogPath $log
    Assert-Equal -Name "tick processes every event in the batch" -Expected 3 -Actual $t1.processed
    Assert-Equal -Name "tick dispatches only the 2 task.* events"  -Expected 2 -Actual $t1.dispatched
    Assert-Equal -Name "recorder delivered 2 events"               -Expected 2 -Actual (@(Get-Content -LiteralPath $marker)).Count
    Assert-Equal -Name "cursor advanced to batch position"         -Expected $t1.position -Actual (Read-EventCursor -BotRoot $cbot)

    # ── Second tick with nothing new → no-op ──
    $t2 = Invoke-EventConsumerTick -BotRoot $cbot -Registry $reg -LogPath $log
    Assert-Equal -Name "idle tick processes nothing"    -Expected 0 -Actual $t2.processed
    Assert-Equal -Name "idle tick delivers nothing new" -Expected 2 -Actual (@(Get-Content -LiteralPath $marker)).Count

    # ── Resume from persisted cursor: a new event is delivered, old ones aren't ──
    Add-EventLine -LogPath $log -Id 'evt_4' -Type 'task.status_changed' -Marker $marker
    $t3 = Invoke-EventConsumerTick -BotRoot $cbot -Registry $reg -LogPath $log
    Assert-Equal -Name "resume tick processes only the new event"  -Expected 1 -Actual $t3.processed
    Assert-Equal -Name "resume tick delivers only the new task.* event" -Expected 3 -Actual (@(Get-Content -LiteralPath $marker)).Count

    # ── At-least-once / replay: rewinding the cursor re-delivers ──
    Save-EventCursor -BotRoot $cbot -Offset 0
    $t4 = Invoke-EventConsumerTick -BotRoot $cbot -Registry $reg -LogPath $log
    Assert-Equal -Name "replay tick re-reads all 4 events"                 -Expected 4 -Actual $t4.processed
    Assert-Equal -Name "replay re-delivers the 3 task.* events (3+3=6)"    -Expected 6 -Actual (@(Get-Content -LiteralPath $marker)).Count
} finally {
    Remove-Item -Recurse -Force $cbot -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $csinks -ErrorAction SilentlyContinue
}

# ── Runspace lifecycle: Start-EventConsumer delivers, Stop tears down ──
$rbot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-consumer-rs-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$rsinkDir = Join-Path $rbot 'src/runtime/Plugins/Events/Sinks/recorder'
New-Item -ItemType Directory -Path (Join-Path $rbot '.control') -Force | Out-Null
New-Item -ItemType Directory -Path $rsinkDir -Force | Out-Null
try {
    @{ name = 'recorder'; subscribed_events = @('task.*'); max_duration = 10 } | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $rsinkDir 'metadata.json') -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $rsinkDir 'script.ps1') -Encoding utf8NoBOM -Value @'
function Invoke-Sink {
    param($Event)
    Add-Content -LiteralPath $Event.data.marker -Value $Event.id -Encoding utf8NoBOM
}
Export-ModuleMember -Function Invoke-Sink
'@

    $rlog    = Join-Path $rbot '.control/activity.jsonl'
    $rmarker = Join-Path $rbot 'deliveries.out'

    $consumer = Start-EventConsumer -BotRoot $rbot -IntervalSeconds 0.5
    Assert-True -Name "Start-EventConsumer returns a running handle" -Condition ($null -ne $consumer -and $consumer.enabled)

    # Append AFTER start (cursor was seeded to EOF), so the consumer must tail it.
    Add-EventLine -LogPath $rlog -Id 'evt_rs1' -Type 'task.created' -Marker $rmarker

    $delivered = $false
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path -LiteralPath $rmarker) { $delivered = $true; break }
        Start-Sleep -Milliseconds 100
    }
    Assert-True -Name "background consumer tails and delivers an appended event" -Condition $delivered

    Stop-EventConsumer -Consumer $consumer
    Assert-True -Name "Stop-EventConsumer signals the stop flag" -Condition ([bool]$consumer.stop_flag[0])
} finally {
    Remove-Item -Recurse -Force $rbot -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Dotbot.Events Sink Discovery + Dispatch + Consumer"

if (-not $allPassed) {
    exit 1
}
