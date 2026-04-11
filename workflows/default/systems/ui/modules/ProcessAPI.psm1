<#
.SYNOPSIS
Process management API module

.DESCRIPTION
Provides process listing, output streaming, stop/kill operations,
whisper messaging, and process launching.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    ProcessesDir = $null
    BotRoot = $null
    ControlDir = $null
}

Import-Module (Join-Path $PSScriptRoot "..\..\runtime\modules\ConsoleSequenceSanitizer.psm1")

function Update-ActivityEventFields {
    param(
        [Parameter(Mandatory)]
        [object]$Event
    )

    if ($Event.PSObject.Properties['message']) {
        $Event.message = ConvertTo-SanitizedConsoleText $Event.message
    }

    return $Event
}

function Initialize-ProcessAPI {
    param(
        [Parameter(Mandatory)] [string]$ProcessesDir,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ControlDir
    )
    $script:Config.ProcessesDir = $ProcessesDir
    $script:Config.BotRoot = $BotRoot
    $script:Config.ControlDir = $ControlDir
}

function Get-ProcessList {
    param(
        [string]$FilterType,
        [string]$FilterStatus
    )
    $processesDir = $script:Config.ProcessesDir

    $processList = @()
    $processFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    $now = [DateTime]::UtcNow

    foreach ($pf in $processFiles) {
        try {
            $proc = Get-Content $pf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json

            # TTL cleanup: remove failed/stopped processes older than 5 minutes
            if ($proc.status -in @('failed', 'stopped') -and $proc.failed_at) {
                $failedTime = [DateTime]::Parse($proc.failed_at)
                if (($now - $failedTime).TotalMinutes -gt 5) {
                    Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue
                    # Also remove activity and whisper files
                    $actFile = Join-Path $processesDir "$($proc.id).activity.jsonl"
                    $whisperFile = Join-Path $processesDir "$($proc.id).whisper.jsonl"
                    $stopFile = Join-Path $processesDir "$($proc.id).stop"
                    Remove-Item $actFile -Force -ErrorAction SilentlyContinue
                    Remove-Item $whisperFile -Force -ErrorAction SilentlyContinue
                    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
                    continue
                }
            }

            # Detect dead PIDs for running/starting processes
            if ($proc.status -in @('running', 'starting') -and $proc.pid) {
                $isAlive = $null -ne (Get-Process -Id $proc.pid -ErrorAction SilentlyContinue)
                if (-not $isAlive) {
                    $proc.status = 'stopped'
                    $proc.failed_at = $now.ToString("o")
                    $proc | Add-Member -NotePropertyName 'error' -NotePropertyValue "Process terminated unexpectedly" -Force
                    $proc = Update-ProcessHeartbeatFields -Process $proc
                    $proc | ConvertTo-Json -Depth 10 | Set-Content -Path $pf.FullName -Force -ErrorAction Stop

                    # Write activity log so the PROCESSES tab output shows what happened
                    $actFile = Join-Path $processesDir "$($proc.id).activity.jsonl"
                    $event = @{ timestamp = $now.ToString("o"); type = "text"; message = "Process terminated unexpectedly (PID $($proc.pid) no longer alive)" } | ConvertTo-Json -Compress
                    Add-Content -Path $actFile -Value $event -ErrorAction SilentlyContinue
                }
            }

            $processList += (Update-ProcessHeartbeatFields -Process $proc)
        } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
    }

    # Apply query filters if present
    if ($FilterType) { $processList = @($processList | Where-Object { $_.type -eq $FilterType }) }
    if ($FilterStatus) { $processList = @($processList | Where-Object { $_.status -eq $FilterStatus }) }

    return @{ processes = @($processList) }
}

function Get-ProcessOutput {
    param(
        [Parameter(Mandatory)] [string]$ProcessId,
        [int]$Position = 0,
        [int]$Tail = 50
    )
    $processesDir = $script:Config.ProcessesDir
    $activityFile = Join-Path $processesDir "$ProcessId.activity.jsonl"

    if ($Tail -le 0) { $Tail = 50 }

    if (Test-Path $activityFile) {
        try {
            $fs = [System.IO.FileStream]::new($activityFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $allText = $sr.ReadToEnd()
            $sr.Close(); $fs.Close()

            $allLines = @($allText -split "`n" | Where-Object { $_.Trim() })
            $totalLines = $allLines.Count

            $events = @()
            $startIdx = if ($Position -gt 0) { $Position } else { [Math]::Max(0, $totalLines - $Tail) }
            for ($li = $startIdx; $li -lt $totalLines; $li++) {
                try { $events += (Update-ActivityEventFields -Event ($allLines[$li] | ConvertFrom-Json)) } catch { Write-BotLog -Level Debug -Message "Malformed JSONL line in activity log" -Exception $_ }
            }

            return @{
                events = @($events)
                position = $totalLines
                total = $totalLines
            }
        } catch {
            return @{ events = @(); position = 0; error = "$_" }
        }
    } else {
        return @{ events = @(); position = 0 }
    }
}

function Stop-ProcessById {
    param(
        [Parameter(Mandatory)] [string]$ProcessId
    )
    $processesDir = $script:Config.ProcessesDir

    $stopFile = Join-Path $processesDir "$ProcessId.stop"
    "stop" | Set-Content -Path $stopFile -Force
    Write-Status "Stop signal sent to process $ProcessId" -Type Info

    return @{ success = $true; process_id = $ProcessId; message = "Stop signal sent" }
}

function Stop-ManagedProcessById {
    param(
        [Parameter(Mandatory)] [string]$ProcessId
    )
    $processesDir = $script:Config.ProcessesDir

    $procFile = Join-Path $processesDir "$ProcessId.json"
    if (Test-Path $procFile) {
        try {
            $procData = Get-Content $procFile -Raw | ConvertFrom-Json
            $pid = $procData.pid
            if ($pid) {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            }
            # Update process registry
            $procData.status = "stopped"
            $procData | Add-Member -NotePropertyName "failed_at" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
            $procData | ConvertTo-Json -Depth 10 | Set-Content -Path $procFile -Force -Encoding utf8NoBOM
            # Create stop signal file for cleanup
            $stopFile = Join-Path $processesDir "$ProcessId.stop"
            "stop" | Set-Content -Path $stopFile -Force
            Write-Status "Killed process $ProcessId (PID: $pid)" -Type Warn

            return @{ success = $true; process_id = $ProcessId; message = "Process killed (PID: $pid)" }
        } catch {
            return @{ success = $false; error = "Kill failed: $_" }
        }
    } else {
        return @{ _statusCode = 404; error = "Process not found: $ProcessId" }
    }
}

function Stop-ProcessByType {
    param(
        [Parameter(Mandatory)] [string]$Type
    )
    $processesDir = $script:Config.ProcessesDir

    $stopped = @()
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($pData.type -eq $Type -and ($pData.status -eq "running" -or $pData.status -eq "starting")) {
                $stopFile = Join-Path $processesDir "$($pData.id).stop"
                "stop" | Set-Content -Path $stopFile -Force
                $stopped += $pData.id
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }
    Write-Status "Stop signal sent to $($stopped.Count) $Type process(es)" -Type Info

    return @{ success = $true; stopped = $stopped; count = $stopped.Count }
}

function Stop-ManagedProcessByType {
    param(
        [Parameter(Mandatory)] [string]$Type
    )
    $processesDir = $script:Config.ProcessesDir

    $killed = @()
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($pData.type -eq $Type -and ($pData.status -eq "running" -or $pData.status -eq "starting")) {
                if ($pData.pid) {
                    Stop-Process -Id $pData.pid -Force -ErrorAction SilentlyContinue
                }
                $pData.status = "stopped"
                $pData | Add-Member -NotePropertyName "failed_at" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
                $pData | ConvertTo-Json -Depth 10 | Set-Content -Path $pf.FullName -Force -Encoding utf8NoBOM
                $stopFile = Join-Path $processesDir "$($pData.id).stop"
                "stop" | Set-Content -Path $stopFile -Force
                $killed += $pData.id
            }
        } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process" -Exception $_ }
    }
    Write-Status "Killed $($killed.Count) $Type process(es)" -Type Warn

    return @{ success = $true; killed = $killed; count = $killed.Count }
}

function Stop-AllManagedProcesses {
    $processesDir = $script:Config.ProcessesDir

    $killed = @()
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($pData.status -eq "running" -or $pData.status -eq "starting") {
                if ($pData.pid) {
                    Stop-Process -Id $pData.pid -Force -ErrorAction SilentlyContinue
                }
                $pData.status = "stopped"
                $pData | Add-Member -NotePropertyName "failed_at" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
                $pData | ConvertTo-Json -Depth 10 | Set-Content -Path $pf.FullName -Force -Encoding utf8NoBOM
                $stopFile = Join-Path $processesDir "$($pData.id).stop"
                "stop" | Set-Content -Path $stopFile -Force
                $killed += $pData.id
            }
        } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process" -Exception $_ }
    }
    Write-Status "Killed all processes ($($killed.Count) total)" -Type Warn

    return @{ success = $true; killed = $killed; count = $killed.Count }
}

function Send-ProcessWhisper {
    param(
        [Parameter(Mandatory)] [string]$ProcessId,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Priority = "normal"
    )
    $processesDir = $script:Config.ProcessesDir

    $whisperFile = Join-Path $processesDir "$ProcessId.whisper.jsonl"
    $whisper = @{
        instruction = $Message
        priority = $Priority
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress

    Add-Content -Path $whisperFile -Value $whisper -Encoding utf8NoBOM
    Write-Status "Whisper sent to process $ProcessId" -Type Success

    return @{ success = $true; process_id = $ProcessId }
}

function Get-ProcessDetail {
    param(
        [Parameter(Mandatory)] [string]$ProcessId
    )
    $processesDir = $script:Config.ProcessesDir

    $procFile = Join-Path $processesDir "$ProcessId.json"
    if (Test-Path $procFile) {
        return Update-ProcessHeartbeatFields -Process (Get-Content $procFile -Raw | ConvertFrom-Json)
    } else {
        return @{ _statusCode = 404; error = "Process not found: $ProcessId" }
    }
}

function Get-MaxConcurrent {
    $botRoot = $script:Config.BotRoot
    $controlDir = $script:Config.ControlDir
    $maxConcurrent = 1
    $settingsPath = Join-Path $botRoot "settings\settings.default.json"
    $controlSettingsPath = Join-Path $controlDir "settings.json"
    foreach ($sp in @($controlSettingsPath, $settingsPath)) {
        if (Test-Path $sp) {
            try {
                $s = Get-Content $sp -Raw | ConvertFrom-Json
                if ($s.scoring -and $s.scoring.max_concurrent_scores -and [int]$s.scoring.max_concurrent_scores -gt $maxConcurrent) {
                    $maxConcurrent = [int]$s.scoring.max_concurrent_scores
                }
                if ($s.execution -and $s.execution.max_concurrent -and [int]$s.execution.max_concurrent -gt $maxConcurrent) {
                    $maxConcurrent = [int]$s.execution.max_concurrent
                }
                if ($maxConcurrent -gt 1) { break }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse max_concurrent setting" -Exception $_ }
        }
    }
    return $maxConcurrent
}

function Start-ProcessLaunch {
    param(
        [Parameter(Mandatory)] [string]$Type,
        [string]$TaskId,
        [string]$Prompt,
        [bool]$Continue = $false,
        [string]$Description,
        [string]$Model,
        [string]$WorkflowName,
        [int]$Slot = -1
    )
    $processesDir = $script:Config.ProcessesDir
    $botRoot = $script:Config.BotRoot
    $controlDir = $script:Config.ControlDir

    # Auto-concurrent: when launching a workflow without an explicit slot,
    # check max_concurrent and delegate to Start-ConcurrentWorkflow if > 1.
    if ($Type -eq 'task-runner' -and $Slot -lt 0) {
        $maxConcurrent = Get-MaxConcurrent
        if ($maxConcurrent -gt 1) {
            return Start-ConcurrentWorkflow -WorkflowName $WorkflowName -Description $Description -MaxConcurrent $maxConcurrent
        }
    }

    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    if (-not (Test-Path $launcherPath)) {
        return @{ success = $false; error = "Launcher script not found" }
    }

    # Build arguments
    $launchArgs = @("-File", "`"$launcherPath`"", "-Type", $Type)

    if ($TaskId) { $launchArgs += @("-TaskId", $TaskId) }
    if ($Prompt) { $launchArgs += @("-Prompt", "`"$($Prompt -replace '"', '\"')`"") }
    if ($Continue) { $launchArgs += "-Continue" }
    if ($Description) { $launchArgs += @("-Description", "`"$($Description -replace '"', '\"')`"") }
    # Only pass -Model when explicitly provided; otherwise let launch-process.ps1 resolve from settings
    if ($Model) { $launchArgs += @("-Model", $Model) }
    if ($WorkflowName) { $launchArgs += @("-Workflow", $WorkflowName) }
    if ($Slot -ge 0) { $launchArgs += @("-Slot", $Slot) }

    # Check settings for debug/verbose
    $settingsFile = Join-Path $controlDir "ui-settings.json"
    if (Test-Path $settingsFile) {
        try {
            $uiSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ([bool]$uiSettings.showDebug) { $launchArgs += "-ShowDebug" }
            if ([bool]$uiSettings.showVerbose) { $launchArgs += "-ShowVerbose" }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    # Launch as separate process
    $startParams = @{ ArgumentList = $launchArgs; PassThru = $true }
    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
    $proc = Start-Process pwsh @startParams

    # Wait briefly for process file to be created
    Start-Sleep -Milliseconds 500

    # Find the process ID from the registry (most recent by started_at)
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    $launchedProcId = $null
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($pData.pid -eq $proc.Id) {
                $launchedProcId = $pData.id
                break
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    $slotSegment = if ($Slot -ge 0) { ", Slot: $Slot" } else { "" }
    Write-Status "Launched $Type process (PID: $($proc.Id)$slotSegment)" -Type Success

    return @{
        success = $true
        process_id = $launchedProcId
        pid = $proc.Id
        type = $Type
        model = $Model
        slot = $Slot
    }
}

function Start-ConcurrentWorkflow {
    param(
        [string]$WorkflowName,
        [string]$Description,
        [int]$MaxConcurrent = 1
    )

    $results = @()
    for ($slot = 0; $slot -lt $MaxConcurrent; $slot++) {
        $desc = if ($MaxConcurrent -gt 1) { "$Description (slot $slot)" } else { $Description }
        $result = Start-ProcessLaunch -Type 'task-runner' -Continue $true -Description $desc -WorkflowName $WorkflowName -Slot $slot
        $results += $result
        if ($slot -lt $MaxConcurrent - 1) { Start-Sleep -Milliseconds 300 }
    }

    return @{
        success = $true
        slots_launched = $results.Count
        processes = $results
    }
}

Export-ModuleMember -Function @(
    'Initialize-ProcessAPI',
    'Get-ProcessList',
    'Get-ProcessOutput',
    'Stop-ProcessById',
    'Stop-ManagedProcessById',
    'Stop-ProcessByType',
    'Stop-ManagedProcessByType',
    'Stop-AllManagedProcesses',
    'Send-ProcessWhisper',
    'Get-ProcessDetail',
    'Start-ProcessLaunch',
    'Start-ConcurrentWorkflow'
)
