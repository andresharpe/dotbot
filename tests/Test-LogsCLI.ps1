#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Tests for `dotbot logs` (src/cli/logs.ps1) and the last-crash
    summary surfaced by `dotbot runtime-status` (issue #657).
.DESCRIPTION
    Exercises the read side of the log-surfacing feature against fixture files:
      - tail of a mixed-shape activity.jsonl (logging events with `message`
        vs. typed state events with from/to/reason),
      - --tail N limiting,
      - --last reading .control/last-crash.json,
      - runtime-status surfacing the crash summary when the runtime isn't running,
      - graceful behaviour when no .bot / no activity log / no crash exists,
      - wiring through bin/dotbot.ps1 (the --flag → splat path).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: Logs CLI Tests (#657)" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$logsScript          = Join-Path $dotbotDir 'src/cli/logs.ps1'
$runtimeStatusScript = Join-Path $dotbotDir 'src/cli/runtime-status.ps1'
$dotbotCli           = Join-Path $dotbotDir 'bin/dotbot.ps1'

# Run a CLI script inside $WorkDir (child pwsh inherits the pushed location),
# returning merged stdout+stderr as one string plus the exit code. Write-Host
# output in a child process lands on stdout, so theme-helper output is captured.
function Invoke-Cli {
    param(
        [Parameter(Mandatory)] [string]$Script,
        [Parameter(Mandatory)] [string]$WorkDir,
        [string[]]$CliArgs = @()
    )
    Push-Location $WorkDir
    try {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Script @CliArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return @{ Output = ($out | Out-String); Code = $code }
}

$projA = $null   # has activity.jsonl + last-crash.json
$projB = $null   # has .bot/.control but no log files
$projC = $null   # no .bot at all
$projD = $null   # write-path: Write-DotbotCrashSummary produces last-crash.json

try {
    # -------------------------------------------------------------------
    # Static checks
    # -------------------------------------------------------------------
    Assert-True -Name "logs.ps1 exists on disk" -Condition (Test-Path $logsScript) -Message "Not found: $logsScript"
    Assert-ValidPowerShellAst -Name "logs.ps1 parses without syntax errors" -Path $logsScript

    # -------------------------------------------------------------------
    # Fixtures
    # -------------------------------------------------------------------
    $projA = New-TestProject
    $controlA = Join-Path $projA '.bot/.control'
    New-Item -ItemType Directory -Path $controlA -Force | Out-Null

    # Mixed-shape activity log: logging-shape events carry `message`; typed
    # state-change events carry from/to/reason instead.
    $activityLines = @(
        '{"timestamp":"2026-07-21T10:00:00Z","type":"info","message":"ALPHA-info-event","phase":"analysis"}'
        '{"timestamp":"2026-07-21T10:00:01Z","type":"workflow_run_started","run_id":"wr_test123","actor":"cli"}'
        '{"timestamp":"2026-07-21T10:00:02Z","type":"error","message":"BRAVO-error-event"}'
        '{"timestamp":"2026-07-21T10:00:03Z","type":"workflow_run_failed","run_id":"wr_test123","from":"running","to":"failed","reason":"CHARLIE-fail-reason"}'
    )
    Set-Content -Path (Join-Path $controlA 'activity.jsonl') -Value $activityLines -Encoding UTF8

    $crash = [ordered]@{
        timestamp   = '2026-07-21T10:05:00Z'
        process_id  = 'proc_abc'
        run_id      = 'wr_test123'
        exit_reason = 'Unexpected termination: DELTA-crash-reason'
        last_task   = [ordered]@{ id = 't_task01'; name = 'ECHO-task-name'; status = 'in-progress' }
        last_events = @(
            [ordered]@{ timestamp = '2026-07-21T10:04:59Z'; type = 'text'; message = 'FOXTROT-last-event' }
        )
    }
    $crash | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $controlA 'last-crash.json') -Encoding UTF8

    # -------------------------------------------------------------------
    # dotbot logs — tail (mixed-shape rendering)
    # -------------------------------------------------------------------
    $r = Invoke-Cli -Script $logsScript -WorkDir $projA -CliArgs @('-Tail', '10')
    Assert-Equal -Name "logs tail exits 0" -Expected 0 -Actual $r.Code -Message $r.Output
    Assert-True -Name "logs tail renders logging-shape message" -Condition ($r.Output -match 'ALPHA-info-event') -Message $r.Output
    Assert-True -Name "logs tail renders error-shape message"   -Condition ($r.Output -match 'BRAVO-error-event') -Message $r.Output
    Assert-True -Name "logs tail renders typed-event reason"    -Condition ($r.Output -match 'CHARLIE-fail-reason') -Message $r.Output
    Assert-True -Name "logs tail renders from->to transition"   -Condition ($r.Output -match 'running -> failed') -Message $r.Output

    # --tail N limiting: N=1 shows only the last line.
    $r = Invoke-Cli -Script $logsScript -WorkDir $projA -CliArgs @('-Tail', '1')
    Assert-True -Name "logs --tail 1 keeps the last event"      -Condition ($r.Output -match 'CHARLIE-fail-reason') -Message $r.Output
    Assert-True -Name "logs --tail 1 drops earlier events"      -Condition (-not ($r.Output -match 'ALPHA-info-event')) -Message $r.Output

    # -------------------------------------------------------------------
    # dotbot logs --last (crash summary)
    # -------------------------------------------------------------------
    $r = Invoke-Cli -Script $logsScript -WorkDir $projA -CliArgs @('-Last')
    Assert-Equal -Name "logs --last exits 0" -Expected 0 -Actual $r.Code -Message $r.Output
    Assert-True -Name "logs --last shows the crash section"     -Condition ($r.Output -match 'LAST CRASH') -Message $r.Output
    Assert-True -Name "logs --last shows the exit reason"       -Condition ($r.Output -match 'DELTA-crash-reason') -Message $r.Output
    Assert-True -Name "logs --last shows the last task"         -Condition ($r.Output -match 'ECHO-task-name') -Message $r.Output
    Assert-True -Name "logs --last shows the last events tail"  -Condition ($r.Output -match 'FOXTROT-last-event') -Message $r.Output

    # -------------------------------------------------------------------
    # runtime-status surfaces the crash summary when not running
    # -------------------------------------------------------------------
    $r = Invoke-Cli -Script $runtimeStatusScript -WorkDir $projA
    Assert-True -Name "runtime-status surfaces LAST CRASH section" -Condition ($r.Output -match 'LAST CRASH') -Message $r.Output
    Assert-True -Name "runtime-status surfaces the crash reason"   -Condition ($r.Output -match 'DELTA-crash-reason') -Message $r.Output

    # -------------------------------------------------------------------
    # Wiring through bin/dotbot.ps1 (--flag → splat path)
    # -------------------------------------------------------------------
    $r = Invoke-Cli -Script $dotbotCli -WorkDir $projA -CliArgs @('logs', '--tail', '3')
    Assert-Equal -Name "dotbot logs (via CLI dispatch) exits 0" -Expected 0 -Actual $r.Code -Message $r.Output
    Assert-True -Name "dotbot logs (via CLI dispatch) renders events" -Condition ($r.Output -match 'CHARLIE-fail-reason') -Message $r.Output

    # -------------------------------------------------------------------
    # Empty-state behaviour: .bot/.control present but no log files
    # -------------------------------------------------------------------
    $projB = New-TestProject
    New-Item -ItemType Directory -Path (Join-Path $projB '.bot/.control') -Force | Out-Null

    $r = Invoke-Cli -Script $logsScript -WorkDir $projB
    Assert-Equal -Name "logs with no activity log exits 1" -Expected 1 -Actual $r.Code -Message $r.Output
    Assert-True -Name "logs with no activity log explains why" -Condition ($r.Output -match 'No activity log') -Message $r.Output

    $r = Invoke-Cli -Script $logsScript -WorkDir $projB -CliArgs @('-Last')
    Assert-Equal -Name "logs --last with no crash exits 0" -Expected 0 -Actual $r.Code -Message $r.Output
    Assert-True -Name "logs --last with no crash reports none" -Condition ($r.Output -match 'No crash recorded') -Message $r.Output

    # -------------------------------------------------------------------
    # No .bot/ at all
    # -------------------------------------------------------------------
    $projC = New-TestProject
    $r = Invoke-Cli -Script $logsScript -WorkDir $projC
    Assert-Equal -Name "logs with no .bot exits 1" -Expected 1 -Actual $r.Code -Message $r.Output
    Assert-True -Name "logs with no .bot points at 'dotbot init'" -Condition ($r.Output -match 'Could not find a \.bot') -Message $r.Output

    # -------------------------------------------------------------------
    # Write path: Write-DotbotCrashSummary (the crash-trap hook) produces a
    # summary that `dotbot logs --last` can read back.
    # -------------------------------------------------------------------
    Import-Module (Join-Path $dotbotDir 'src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1') -Force -DisableNameChecking

    $projD = New-TestProject
    $botD = Join-Path $projD '.bot'
    $procDir = Join-Path $botD '.control/processes'
    New-Item -ItemType Directory -Path $procDir -Force | Out-Null

    $procId = 'proc_writetest'
    $procActivity = @(
        '{"timestamp":"2026-07-21T11:00:00Z","type":"text","message":"GOLF-early-event"}'
        '{"timestamp":"2026-07-21T11:00:01Z","type":"text","message":"HOTEL-terminated-event"}'
    )
    Set-Content -Path (Join-Path $procDir "$procId.activity.jsonl") -Value $procActivity -Encoding UTF8

    $proc = @{ run_id = 'wr_write1'; task_id = 't_wt01'; task_name = 'INDIA-task'; status = 'stopped' }
    Write-DotbotCrashSummary -BotRoot $botD -ProcessId $procId -Process $proc -Reason 'Unexpected termination: JULIET-reason'

    $crashFile = Join-Path $botD '.control/last-crash.json'
    Assert-PathExists   -Name "Write-DotbotCrashSummary creates last-crash.json" -Path $crashFile
    Assert-ValidJson    -Name "last-crash.json is valid JSON" -Path $crashFile
    Assert-FileContains -Name "crash summary carries the exit reason"      -Path $crashFile -Pattern 'JULIET-reason'
    Assert-FileContains -Name "crash summary carries the last events tail"  -Path $crashFile -Pattern 'HOTEL-terminated-event'
    Assert-FileContains -Name "crash summary carries the last task"        -Path $crashFile -Pattern 'INDIA-task'

    $r = Invoke-Cli -Script $logsScript -WorkDir $projD -CliArgs @('-Last')
    Assert-True -Name "logs --last renders the written crash summary" -Condition ($r.Output -match 'JULIET-reason') -Message $r.Output
}
finally {
    if ($projA) { Remove-TestProject -Path $projA }
    if ($projB) { Remove-TestProject -Path $projB }
    if ($projC) { Remove-TestProject -Path $projC }
    if ($projD) { Remove-TestProject -Path $projD }
}

$ok = Write-TestSummary -LayerName "Layer 2: Logs CLI (#657)"
if ($ok) { exit 0 } else { exit 1 }
