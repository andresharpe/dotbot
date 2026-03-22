#!/usr/bin/env pwsh
<#
.SYNOPSIS
Operator helper script for the steering channel.

.DESCRIPTION
Send whispers to running DOTBOT sessions and monitor their status.

.EXAMPLE
.\steering.ps1 whisper -SessionId "proc-a1b2c3" -Message "Focus on tests" -Priority normal

.EXAMPLE
.\steering.ps1 status

.EXAMPLE
.\steering.ps1 watch

.EXAMPLE
.\steering.ps1 abort -SessionId "proc-a1b2c3"
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('whisper', 'status', 'watch', 'list', 'abort', 'history')]
    [string]$Command = 'status',

    [Parameter()]
    [string]$SessionId,

    [Parameter()]
    [Alias('m')]
    [string]$Message,

    [Parameter()]
    [ValidateSet('normal', 'urgent', 'abort')]
    [string]$Priority = 'normal'
)

# Import theme for consistent output
$themePath = Join-Path $PSScriptRoot "..\..\systems\runtime\modules\DotBotTheme.psm1"
if (Test-Path $themePath) {
    Import-Module $themePath -Force
    $t = Get-DotBotTheme
} else {
    # Fallback if theme not available
    $t = @{
        Primary = ''; Success = ''; Error = ''; Warning = ''; Muted = ''; Reset = ''
    }
}

$controlDir = Join-Path $PSScriptRoot "..\..\..\.control"
$controlDir = [System.IO.Path]::GetFullPath($controlDir)
$processesDir = Join-Path $controlDir "processes"
$statusFile = Join-Path $controlDir "steering-status.json"

function Get-RunningProcesses {
    $procs = @()
    if (Test-Path $processesDir) {
        $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($pf in $procFiles) {
            try {
                $proc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                if ($proc.status -eq 'running') {
                    $procs += $proc
                }
            } catch {}
        }
    }
    return $procs
}

function Send-Whisper {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('normal', 'urgent', 'abort')]
        [string]$Priority = 'normal'
    )

    if (-not (Test-Path $processesDir)) {
        New-Item -ItemType Directory -Path $processesDir -Force | Out-Null
    }

    $whisperFile = Join-Path $processesDir "$SessionId.whisper.jsonl"
    $whisper = @{
        instruction = $Message
        priority = $Priority
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress

    Add-Content -Path $whisperFile -Value $whisper -Encoding utf8NoBOM

    Write-Host "$($t.Success)$($t.Reset) Whisper sent to $($t.Primary)$SessionId$($t.Reset)"
    Write-Host "  $($t.Muted)Priority:$($t.Reset) $Priority"
    Write-Host "  $($t.Muted)Message:$($t.Reset) $Message"
}

function Get-SteeringStatus {
    if (-not (Test-Path $statusFile)) {
        Write-Host "$($t.Warning)$($t.Reset) No steering status file found"
        Write-Host "  $($t.Muted)Either no session is running or it hasn't posted status yet.$($t.Reset)"
        return
    }

    try {
        $status = Get-Content $statusFile -Raw | ConvertFrom-Json
        $updatedAt = [DateTime]::Parse($status.updated_at)
        $age = (Get-Date).ToUniversalTime() - $updatedAt
        $ageStr = if ($age.TotalMinutes -lt 1) { "$([int]$age.TotalSeconds)s ago" }
                  elseif ($age.TotalHours -lt 1) { "$([int]$age.TotalMinutes)m ago" }
                  else { "$([int]$age.TotalHours)h ago" }

        Write-Host ""
        Write-Host "$($t.Primary)--- Steering Status ---$($t.Reset)"
        Write-Host "$($t.Primary)|$($t.Reset) $($t.Muted)Session:$($t.Reset)     $($status.session_id)"
        Write-Host "$($t.Primary)|$($t.Reset) $($t.Muted)Status:$($t.Reset)      $($status.status)"
        if ($status.next_action) {
            Write-Host "$($t.Primary)|$($t.Reset) $($t.Muted)Next:$($t.Reset)        $($status.next_action)"
        }
        Write-Host "$($t.Primary)|$($t.Reset) $($t.Muted)Updated:$($t.Reset)     $ageStr"
        Write-Host "$($t.Primary)|$($t.Reset) $($t.Muted)Whisper Idx:$($t.Reset) $($status.last_whisper_index)"
        Write-Host ""
    } catch {
        Write-Host "$($t.Error)x$($t.Reset) Failed to read status: $_"
    }
}

function Watch-SteeringStatus {
    Write-Host "$($t.Primary)Watching steering status...$($t.Reset) (Ctrl+C to stop)"
    Write-Host ""

    $lastContent = ""
    while ($true) {
        if (Test-Path $statusFile) {
            $content = Get-Content $statusFile -Raw
            if ($content -ne $lastContent) {
                Clear-Host
                Write-Host "$($t.Muted)$(Get-Date -Format 'HH:mm:ss')$($t.Reset) Steering status updated"
                Get-SteeringStatus
                $lastContent = $content
            }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Get-RunningSessions {
    Write-Host ""
    Write-Host "$($t.Primary)Running Processes$($t.Reset)"
    Write-Host "$($t.Muted)----------------------------------------$($t.Reset)"

    $procs = Get-RunningProcesses
    if ($procs.Count -gt 0) {
        foreach ($proc in $procs) {
            Write-Host "$($t.Success)o$($t.Reset) $($proc.id) [$($proc.type)]"
            Write-Host "  $($t.Muted)Model:$($t.Reset) $($proc.model)"
            Write-Host "  $($t.Muted)Started:$($t.Reset) $($proc.started_at)"
            if ($proc.heartbeat_status) {
                Write-Host "  $($t.Muted)Status:$($t.Reset) $($proc.heartbeat_status)"
            }
        }
    } else {
        Write-Host "$($t.Muted)No running processes detected$($t.Reset)"
    }
    Write-Host ""
}

function Send-Abort {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    Send-Whisper -SessionId $SessionId -Message "ABORT: Commit any work in progress and exit gracefully." -Priority "abort"
    Write-Host ""
    Write-Host "$($t.Warning)!$($t.Reset) Abort signal sent. Session should commit WIP and exit."
}

function Get-WhisperHistory {
    Write-Host ""
    Write-Host "$($t.Primary)Whisper History$($t.Reset)"
    Write-Host "$($t.Muted)----------------------------------------$($t.Reset)"

    if (-not (Test-Path $processesDir)) {
        Write-Host "$($t.Muted)No whispers recorded yet.$($t.Reset)"
        return
    }

    $whisperFiles = Get-ChildItem -Path $processesDir -Filter "*.whisper.jsonl" -File -ErrorAction SilentlyContinue
    if ($whisperFiles.Count -eq 0) {
        Write-Host "$($t.Muted)No whispers recorded yet.$($t.Reset)"
        return
    }

    foreach ($wf in $whisperFiles) {
        $procId = $wf.BaseName -replace '\.whisper$', ''
        Write-Host "$($t.Primary)Process: $procId$($t.Reset)"
        $lines = Get-Content $wf.FullName -Encoding utf8
        $index = 0
        foreach ($line in $lines) {
            if ($line.Trim()) {
                $index++
                try {
                    $whisper = $line | ConvertFrom-Json
                    $ts = [DateTime]::Parse($whisper.timestamp).ToLocalTime().ToString("HH:mm:ss")
                    $priorityColor = switch ($whisper.priority) {
                        'urgent' { $t.Warning }
                        'abort' { $t.Error }
                        default { $t.Muted }
                    }
                    Write-Host "$($t.Muted)[$index]$($t.Reset) $ts $priorityColor[$($whisper.priority)]$($t.Reset)"
                    Write-Host "     $($whisper.instruction)"
                } catch {
                    Write-Host "$($t.Muted)[$index]$($t.Reset) $($t.Error)(malformed)$($t.Reset)"
                }
            }
        }
        Write-Host ""
    }
}

# Main command dispatch
switch ($Command) {
    'whisper' {
        if (-not $SessionId) {
            # Try to find a running process to target
            $procs = Get-RunningProcesses
            if ($procs.Count -eq 1) {
                $SessionId = $procs[0].id
                Write-Host "$($t.Muted)Using running process: $SessionId$($t.Reset)"
            } elseif ($procs.Count -gt 1) {
                Write-Host "$($t.Error)x$($t.Reset) Multiple processes running. Specify -SessionId:"
                foreach ($p in $procs) {
                    Write-Host "  $($p.id) [$($p.type)]"
                }
                exit 1
            } else {
                Write-Host "$($t.Error)x$($t.Reset) -SessionId required (no running processes detected)"
                exit 1
            }
        }
        if (-not $Message) {
            Write-Host "$($t.Error)x$($t.Reset) -Message required"
            exit 1
        }
        Send-Whisper -SessionId $SessionId -Message $Message -Priority $Priority
    }
    'status' {
        Get-SteeringStatus
    }
    'watch' {
        Watch-SteeringStatus
    }
    'list' {
        Get-RunningSessions
    }
    'abort' {
        if (-not $SessionId) {
            # Try to find a running process to target
            $procs = Get-RunningProcesses
            if ($procs.Count -eq 1) {
                $SessionId = $procs[0].id
                Write-Host "$($t.Muted)Using running process: $SessionId$($t.Reset)"
            } elseif ($procs.Count -gt 1) {
                Write-Host "$($t.Error)x$($t.Reset) Multiple processes running. Specify -SessionId:"
                foreach ($p in $procs) {
                    Write-Host "  $($p.id) [$($p.type)]"
                }
                exit 1
            } else {
                Write-Host "$($t.Error)x$($t.Reset) -SessionId required (no running processes detected)"
                exit 1
            }
        }
        Send-Abort -SessionId $SessionId
    }
    'history' {
        Get-WhisperHistory
    }
}
