<#
.SYNOPSIS
Control signal, whisper, and activity log API module

.DESCRIPTION
Provides control signal management (start/stop/pause/resume/reset),
operator whisper channel, and activity log tail streaming.
Extracted from server.ps1 for modularity.
#>

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

$script:Config = @{
    ControlDir = $null
    ProcessesDir = $null
    BotRoot = $null
}

function Initialize-ControlAPI {
    param(
        [Parameter(Mandatory)] [string]$ControlDir,
        [Parameter(Mandatory)] [string]$ProcessesDir,
        [Parameter(Mandatory)] [string]$BotRoot
    )
    $script:Config.ControlDir = $ControlDir
    $script:Config.ProcessesDir = $ProcessesDir
    $script:Config.BotRoot = $BotRoot
}

function Set-ControlSignal {
    param(
        [string]$Action,
        [string]$Mode = "execution"  # "execution", "analysis", or "both"
    )

    $controlDir = $script:Config.ControlDir
    $processesDir = $script:Config.ProcessesDir
    $botRoot = $script:Config.BotRoot
    $validActions = @("start", "stop", "pause", "resume", "reset")
    $validModes = @("execution", "analysis", "both")

    if ($Action -notin $validActions) {
        return @{ success = $false; message = "Invalid action: $Action" }
    }

    if ($Mode -and $Mode -notin $validModes) {
        $Mode = "execution"  # Default to execution if invalid
    }

    # Ensure control directory exists
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    # Handle different actions
    switch ($Action) {
        "pause" {
            # Remove resume signal if exists, keep running signal
            $resumeSignal = Join-Path $controlDir "resume.signal"
            if (Test-Path $resumeSignal) { Remove-Item $resumeSignal -Force }

            # Create pause signal
            $signalFile = Join-Path $controlDir "pause.signal"
            @{
                action = $Action
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            } | ConvertTo-Json | Set-Content -Path $signalFile -Force
        }
        "resume" {
            # Remove pause signal to resume from pause
            $pauseSignal = Join-Path $controlDir "pause.signal"
            if (Test-Path $pauseSignal) { Remove-Item $pauseSignal -Force }

            # Remove per-process .stop files to cancel pending stops
            if (Test-Path $processesDir) {
                Get-ChildItem -Path $processesDir -Filter "*.stop" -File -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
        "stop" {
            # Remove pause signal if exists
            $pauseSignal = Join-Path $controlDir "pause.signal"
            if (Test-Path $pauseSignal) { Remove-Item $pauseSignal -Force }

            # Create stop files for all running/starting processes in registry
            if (Test-Path $processesDir) {
                $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
                foreach ($pf in $procFiles) {
                    try {
                        $proc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                        if ($proc.status -in @('running', 'starting')) {
                            $stopFile = Join-Path $processesDir "$($proc.id).stop"
                            "stop" | Set-Content -Path $stopFile -Force
                        }
                    } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
                }
            }
        }
        "start" {
            # Start action - launch process(es) via unified launcher
            $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"

            if (-not (Test-Path $launcherPath)) {
                return @{ success = $false; message = "Launcher script not found" }
            }

            # Check settings for debug mode and model selection
            $settingsFile = Join-Path $controlDir "ui-settings.json"
            $showDebug = $false
            $showVerbose = $false
            $analysisModel = "Opus"
            $executionModel = "Opus"
            if (Test-Path $settingsFile) {
                try {
                    $uiSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
                    $showDebug = [bool]$uiSettings.showDebug
                    $showVerbose = [bool]$uiSettings.showVerbose
                    if ($uiSettings.analysisModel) { $analysisModel = $uiSettings.analysisModel }
                    if ($uiSettings.executionModel) { $executionModel = $uiSettings.executionModel }
                } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
            }

            $launched = @()

            # Launch analysis process if mode is "analysis" or "both"
            if ($Mode -in @("analysis", "both")) {
                $args = @("-File", "`"$launcherPath`"", "-Type", "analysis", "-Continue", "-Model", $analysisModel)
                if ($showDebug) { $args += "-ShowDebug" }
                if ($showVerbose) { $args += "-ShowVerbose" }
                $startParams = @{ ArgumentList = $args }
                if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
                Start-Process pwsh @startParams
                $launched += "analysis"
                Write-Status "Launched analysis process with model: $analysisModel" -Type Success
            }

            # Launch execution process if mode is "execution" or "both"
            if ($Mode -in @("execution", "both")) {
                $args = @("-File", "`"$launcherPath`"", "-Type", "execution", "-Continue", "-Model", $executionModel)
                if ($showDebug) { $args += "-ShowDebug" }
                if ($showVerbose) { $args += "-ShowVerbose" }
                $startParams = @{ ArgumentList = $args }
                if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
                Start-Process pwsh @startParams
                $launched += "execution"
                Write-Status "Launched execution process with model: $executionModel" -Type Success
            }

            if ($launched.Count -eq 0) {
                return @{ success = $false; message = "No processes launched" }
            }

            return @{
                success = $true
                action = $Action
                mode = $Mode
                launched = $launched
                message = "Launched: $($launched -join ', ')"
            }
        }
        "reset" {
            # Clean up per-process .stop files
            if (Test-Path $processesDir) {
                Get-ChildItem -Path $processesDir -Filter "*.stop" -File -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

                # Set all running/starting process registry entries to stopped
                $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
                foreach ($pf in $procFiles) {
                    try {
                        $proc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                        if ($proc.status -in @('running', 'starting')) {
                            $proc.status = 'stopped'
                            $proc | Add-Member -NotePropertyName 'failed_at' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
                            $proc | ConvertTo-Json -Depth 10 | Set-Content -Path $pf.FullName -Force -Encoding utf8NoBOM
                        }
                    } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
                }
            }

            # Clear remaining control signals (pause only — legacy signals removed)
            $pauseSignal = Join-Path $controlDir "pause.signal"
            if (Test-Path $pauseSignal) { Remove-Item $pauseSignal -Force }

            # Clear session lock
            $lockFile = Join-Path $botRoot "workspace\sessions\runs\session.lock"
            if (Test-Path $lockFile) { Remove-Item $lockFile -Force }

            # Update session state to stopped
            $stateFile = Join-Path $botRoot "workspace\sessions\runs\session-state.json"
            if (Test-Path $stateFile) {
                $state = Get-Content $stateFile -Raw | ConvertFrom-Json
                $state.status = "stopped"
                $state.current_task_id = $null
                $state | ConvertTo-Json -Depth 5 | Set-Content $stateFile
            }

            Write-Status "Reset complete - cleared all stale state" -Type Success
        }
    }

    return @{
        success = $true
        action = $Action
        message = "Signal sent: $Action"
    }
}

function Send-WhisperToInstance {
    param(
        [string]$InstanceType,
        [string]$Message,
        [string]$Priority = "normal"
    )
    $processesDir = $script:Config.ProcessesDir

    # Find running processes of the given type from the process registry
    $targetProcs = @()
    if (Test-Path $processesDir) {
        $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($pf in $procFiles) {
            try {
                $proc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                if ($proc.status -eq 'running' -and $proc.type -eq $InstanceType) {
                    $targetProcs += $proc
                }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }
    }

    if ($targetProcs.Count -eq 0) {
        return @{ success = $false; error = "No $InstanceType instance running" }
    }

    # Send whisper to each matching process
    $sentTo = @()
    foreach ($proc in $targetProcs) {
        $whisperFile = Join-Path $processesDir "$($proc.id).whisper.jsonl"
        $whisper = @{
            instruction = $Message
            priority = $Priority
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json -Compress

        Add-Content -Path $whisperFile -Value $whisper -Encoding utf8NoBOM
        $sentTo += $proc.id
    }

    Write-Status "Whisper sent to $($sentTo.Count) $InstanceType process(es)" -Type Success

    return @{
        success = $true
        instance_type = $InstanceType
        sent_to = $sentTo
    }
}

function Get-ActivityTail {
    param(
        [long]$Position = 0,
        [int]$TailLines = 0
    )
    $botRoot = $script:Config.BotRoot
    $logPath = Join-Path $botRoot ".control\activity.jsonl"

    if (-not (Test-Path $logPath)) {
        return @{ events = @(); position = 0 }
    }

    try {
        # If tail is requested (initial load), read last N lines
        if ($TailLines -gt 0 -and $Position -eq 0) {
            $stream = [System.IO.FileStream]::new(
                $logPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            $reader = [System.IO.StreamReader]::new($stream)
            $allText = $reader.ReadToEnd()
            $newPosition = $stream.Position
            $reader.Close()
            $stream.Close()
            $allLines = ($allText -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last $TailLines
            $events = @()
            foreach ($line in $allLines) {
                if ($line) {
                    try {
                        $events += (Update-ActivityEventFields -Event ($line | ConvertFrom-Json))
                    } catch {
                        # Skip malformed lines
                    }
                }
            }

            return @{
                events = $events
                position = $newPosition
            }
        } else {
            # Normal streaming from position
            $stream = [System.IO.FileStream]::new(
                $logPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            $stream.Seek($Position, 'Begin') | Out-Null
            $reader = [System.IO.StreamReader]::new($stream)

            $events = @()
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line) {
                    try {
                        $events += (Update-ActivityEventFields -Event ($line | ConvertFrom-Json))
                    } catch {
                        # Skip malformed lines
                    }
                }
            }

            $newPosition = $stream.Position
            $reader.Close()
            $stream.Close()

            return @{
                events = $events
                position = $newPosition
            }
        }
    } catch {
        return @{
            events = @()
            position = 0
            error = "Failed to read activity log: $_"
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-ControlAPI',
    'Set-ControlSignal',
    'Send-WhisperToInstance',
    'Get-ActivityTail'
)
