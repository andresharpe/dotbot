function Invoke-SteeringHeartbeat {
    <#
    .SYNOPSIS
    Post status and check for whispers from the operator.

    .DESCRIPTION
    Bidirectional communication channel for autonomous sessions.
    - Updates process registry with current status
    - Returns any new whispers addressed to this process
    - Tracks whisper index to only return new whispers

    Requires process_id to identify the process in the registry.
    #>
    param(
        [hashtable]$Arguments
    )

    $sessionId = $Arguments['session_id']
    $processId = $Arguments['process_id']
    $status = $Arguments['status']
    $nextAction = $Arguments['next_action']

    if (-not $sessionId) {
        return @{
            success = $false
            error = "session_id is required"
        }
    }

    if (-not $processId) {
        return @{
            success = $false
            error = "process_id is required"
        }
    }

    if (-not $status) {
        return @{
            success = $false
            error = "status is required"
        }
    }

    $controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $controlDir = [System.IO.Path]::GetFullPath($controlDir)

    # Ensure control directory exists
    if (-not (Test-Path $controlDir)) {
        New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
    }

    $processesDir = Join-Path $controlDir "processes"
    $processFile = Join-Path $processesDir "$processId.json"
    $whisperFile = Join-Path $processesDir "$processId.whisper.jsonl"

    if (-not (Test-Path $processFile)) {
        return @{
            success = $false
            error = "Process file not found: $processId"
        }
    }

    # Read existing process data
    $lastWhisperIndex = 0
    try {
        $processData = Get-Content $processFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $processData.last_whisper_index) {
            $lastWhisperIndex = $processData.last_whisper_index
        }
    } catch {
        return @{
            success = $false
            error = "Failed to read process file: $_"
        }
    }

    # Read whispers for this process
    $whispers = @()
    $currentIndex = 0

    if (Test-Path $whisperFile) {
        try {
            $lines = Get-Content -Path $whisperFile -Encoding utf8 -ErrorAction Stop
            foreach ($line in $lines) {
                if ($line.Trim()) {
                    $currentIndex++
                    if ($currentIndex -gt $lastWhisperIndex) {
                        try {
                            $w = $line | ConvertFrom-Json -ErrorAction Stop
                            $whispers += @{
                                instruction = $w.instruction
                                priority = $w.priority
                                timestamp = $w.timestamp
                            }
                        } catch {
                            # Skip malformed whisper lines
                        }
                    }
                }
            }
        } catch {
            # Whisper file doesn't exist or is empty - that's fine
        }
    }

    # Update process file with heartbeat info (atomic write)
    $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
    $processData.last_whisper_index = $currentIndex
    $processData.heartbeat_status = $status
    $processData.heartbeat_next_action = if ($nextAction) { $nextAction } else { $null }

    try {
        $tempFile = "$processFile.tmp"
        $processData | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
        Move-Item -Path $tempFile -Destination $processFile -Force
    } catch {
        return @{
            success = $false
            error = "Failed to write process file: $_"
        }
    }

    return @{
        success = $true
        process_id = $processId
        whispers = $whispers
        whisper_count = $whispers.Count
    }
}
