<#
.SYNOPSIS
    Structured logging module for dotbot.

.DESCRIPTION
    Provides centralized, structured JSONL logging with levels (Debug, Info, Warn, Error, Fatal),
    automatic log rotation, and backward-compatible activity log integration.

    Output: .bot/.control/logs/dotbot-{date}.jsonl
    Each line: {ts, level, msg, correlation_id, process_id, task_id, phase, pid, error, stack}

    Info+ events are also written to activity.jsonl for UI oscilloscope backward compat.

    Zero external module dependencies — uses only .NET APIs and PowerShell built-ins.
#>

#region Module State

$script:LogDir          = $null
$script:ControlDir      = $null
$script:FileLevel       = 'Debug'
$script:ConsoleLevel    = 'Info'
$script:ConsoleEnabled  = $true
$script:RetentionDays   = 7
$script:MaxFileSizeMB   = 50
$script:Initialized     = $false
$script:ProjectRoot     = $null
$script:FileRetryCount  = 3
$script:FileRetryBaseMs = 50

$script:LevelOrder = @{
    'Debug' = 0
    'Info'  = 1
    'Warn'  = 2
    'Error' = 3
    'Fatal' = 4
}

$script:LevelToActivityType = @{
    'Info'  = 'info'
    'Warn'  = 'warning'
    'Error' = 'error'
    'Fatal' = 'fatal'
}

#endregion

#region Public Functions

function Initialize-DotBotLog {
    <#
    .SYNOPSIS
        Initializes the structured logging system with configuration.
    .DESCRIPTION
        Idempotent — can be called multiple times (e.g., first with defaults, then with settings).
        Also runs log rotation on each call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDir,

        [Parameter(Mandatory)]
        [string]$ControlDir,

        [string]$ProjectRoot,

        [ValidateSet('Debug','Info','Warn','Error','Fatal')]
        [string]$FileLevel = 'Debug',

        [ValidateSet('Debug','Info','Warn','Error','Fatal')]
        [string]$ConsoleLevel = 'Info',

        [bool]$ConsoleEnabled = $true,

        [int]$RetentionDays = 7,

        [int]$MaxFileSizeMB = 50,

        [int]$FileRetryCount = 3,

        [int]$FileRetryBaseMs = 50
    )

    $script:LogDir          = $LogDir
    $script:ControlDir      = $ControlDir
    $script:ProjectRoot     = $ProjectRoot
    $script:FileLevel       = $FileLevel
    $script:ConsoleLevel    = $ConsoleLevel
    $script:ConsoleEnabled  = $ConsoleEnabled
    $script:RetentionDays   = $RetentionDays
    $script:MaxFileSizeMB   = $MaxFileSizeMB
    $script:FileRetryCount  = $FileRetryCount
    $script:FileRetryBaseMs = $FileRetryBaseMs

    # Create log directory
    if (-not (Test-Path $script:LogDir)) {
        New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
    }

    $script:Initialized = $true

    # Run rotation once per initialization
    Rotate-DotBotLog
}

function Write-BotLog {
    <#
    .SYNOPSIS
        Writes a structured log entry to the JSONL log file.
    .DESCRIPTION
        Core logging function. Writes to structured JSONL log, activity.jsonl (Info+),
        per-process activity log, and console (themed when DotBotTheme is loaded).
    .PARAMETER Level
        Log severity: Debug, Info, Warn, Error, Fatal.
    .PARAMETER Message
        The log message.
    .PARAMETER Context
        Optional hashtable of additional context fields merged into the log entry.
    .PARAMETER Exception
        Optional ErrorRecord to include error message and stack trace.
    .PARAMETER ProcessId
        Optional process ID override. Defaults to $env:DOTBOT_PROCESS_ID.
    .PARAMETER CorrelationId
        Optional correlation ID override. Defaults to $env:DOTBOT_CORRELATION_ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug','Info','Warn','Error','Fatal')]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [hashtable]$Context,

        [System.Management.Automation.ErrorRecord]$Exception,

        [string]$ProcessId,

        [string]$CorrelationId,

        [switch]$ForceDisplay
    )

    # Auto-initialize if not yet initialized — discover log dir from module location
    if (-not $script:Initialized) {
        $autoControlDir = $null
        # Walk up from PSScriptRoot to find .control dir
        # DotBotLog lives at .bot/systems/runtime/modules/ — .control is at .bot/.control
        $botRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        if ($botRoot) {
            $autoControlDir = Join-Path $botRoot ".control"
        }
        if ($autoControlDir -and (Test-Path (Split-Path -Parent $autoControlDir))) {
            $autoLogDir = Join-Path $autoControlDir "logs"
            $autoProjectRoot = Split-Path -Parent $botRoot
            Initialize-DotBotLog -LogDir $autoLogDir -ControlDir $autoControlDir -ProjectRoot $autoProjectRoot
        } else {
            # Cannot auto-initialize — silently return
            return
        }
    }

    # Three-way level gate: file, console, and activity (always Info+)
    $levelOrd = $script:LevelOrder[$Level]
    $meetsFileLevel    = $levelOrd -ge $script:LevelOrder[$script:FileLevel]
    $meetsConsoleLevel = $script:ConsoleEnabled -and ($ForceDisplay -or ($levelOrd -ge $script:LevelOrder[$script:ConsoleLevel]))
    $shouldWriteActivity = $levelOrd -ge $script:LevelOrder['Info']

    if (-not $meetsFileLevel -and -not $meetsConsoleLevel -and -not $shouldWriteActivity) {
        return
    }

    # Sanitize message — strip absolute paths (inline, no PathSanitizer dependency)
    $sanitizedMessage = $Message
    if ($script:ProjectRoot -and $script:ProjectRoot.Length -gt 0) {
        try {
            $sanitizedMessage = $Message -replace [regex]::Escape($script:ProjectRoot), '.'
        } catch {
            # Regex escape failed — use original message
        }
    }

    # Resolve process ID and correlation ID
    $effectiveProcessId = if ($ProcessId) { $ProcessId } else { $env:DOTBOT_PROCESS_ID }
    $effectiveCorrelationId = if ($CorrelationId) { $CorrelationId } else { $env:DOTBOT_CORRELATION_ID }

    # Build structured log entry
    $entry = [ordered]@{
        ts             = (Get-Date).ToUniversalTime().ToString("o")
        level          = $Level
        msg            = $sanitizedMessage
        correlation_id = $effectiveCorrelationId
        process_id     = $effectiveProcessId
        task_id        = $env:DOTBOT_CURRENT_TASK_ID
        phase          = $env:DOTBOT_CURRENT_PHASE
        pid            = $PID
    }

    # Add exception details
    if ($Exception) {
        $entry.error = $Exception.Exception.Message
        $entry.stack = $Exception.ScriptStackTrace
    }

    # Merge context (keys that don't collide with core fields)
    if ($Context) {
        foreach ($key in $Context.Keys) {
            if (-not $entry.Contains($key)) {
                $entry[$key] = $Context[$key]
            }
        }
    }

    $jsonLine = $entry | ConvertTo-Json -Compress

    # 1. Write to structured log file (with size-based rollover)
    if ($meetsFileLevel) {
        $logFilePath = Get-CurrentLogFilePath
        Write-JsonlLine -Path $logFilePath -Line $jsonLine
    }

    # 2. Activity log integration — always for Info+, regardless of file_level
    if ($shouldWriteActivity) {
        $activityType = if ($Context -and $Context.activity_type) {
            $Context.activity_type
        } else {
            $script:LevelToActivityType[$Level]
        }
        $effectivePhase = if ($Context -and $Context.phase_override) {
            $Context.phase_override
        } elseif ($env:DOTBOT_CURRENT_PHASE) {
            $env:DOTBOT_CURRENT_PHASE
        } else {
            $null
        }

        $activityEntry = @{
            timestamp      = $entry.ts
            type           = $activityType
            message        = $sanitizedMessage
            correlation_id = $effectiveCorrelationId
            task_id        = $env:DOTBOT_CURRENT_TASK_ID
            phase          = $effectivePhase
        } | ConvertTo-Json -Compress

        # Global activity.jsonl
        $activityPath = Join-Path $script:ControlDir "activity.jsonl"
        Write-JsonlLine -Path $activityPath -Line $activityEntry

        # Per-process activity log
        if ($effectiveProcessId) {
            $processActivityPath = Join-Path (Join-Path $script:ControlDir "processes") "$effectiveProcessId.activity.jsonl"
            Write-JsonlLine -Path $processActivityPath -Line $activityEntry
        }
    }

    # 3. Console output (themed when DotBotTheme is loaded)
    if ($meetsConsoleLevel) {
        Write-BotLogConsole -Level $Level -Message $sanitizedMessage -Exception $Exception
    }
}

function Rotate-DotBotLog {
    <#
    .SYNOPSIS
        Removes structured log files older than the configured retention period.
        Also cleans up legacy diag-*.log files.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Initialized -or -not $script:LogDir -or -not (Test-Path $script:LogDir)) {
        return
    }

    try {
        $cutoff = (Get-Date).AddDays(-$script:RetentionDays)

        # Clean structured log files
        Get-ChildItem -Path $script:LogDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                try { Remove-Item $_.FullName -Force } catch { }
            }

        # Clean legacy diag files in .control
        if ($script:ControlDir -and (Test-Path $script:ControlDir)) {
            Get-ChildItem -Path $script:ControlDir -Filter "diag-*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                ForEach-Object {
                    try { Remove-Item $_.FullName -Force } catch { }
                }
        }
    } catch {
        # Rotation is best-effort — don't crash
    }
}

function Write-Diag {
    <#
    .SYNOPSIS
        Backward-compatible wrapper — delegates to Write-BotLog -Level Debug.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Msg
    )

    Write-BotLog -Level Debug -Message $Msg
}

#endregion

#region Private Functions

function Write-BotLogConsole {
    <#
    .SYNOPSIS
        Writes themed console output for a log entry.
    #>
    param(
        [string]$Level,
        [string]$Message,
        [System.Management.Automation.ErrorRecord]$Exception
    )

    $icons = @{
        Debug = '.'
        Info  = '›'
        Warn  = '⚠'
        Error = '✗'
        Fatal = '✗'
    }

    $icon = $icons[$Level]
    $exMsg = if ($Exception) { " — $($Exception.Exception.Message)" } else { '' }
    $text = "  $icon $Message$exMsg"

    # Try to use DotBotTheme colors if loaded
    $theme = $null
    if (Get-Module DotBotTheme) {
        try { $theme = Get-DotBotTheme } catch { }
    }

    if ($theme) {
        $colorMap = @{
            Debug = $theme.Muted
            Info  = $theme.Cyan
            Warn  = $theme.Amber
            Error = $theme.Red
            Fatal = $theme.Red
        }
        $color = $colorMap[$Level]
        $reset = $theme.Reset
        if ($color -and $reset) {
            Write-Host "${color}${text}${reset}"
            return
        }
    }

    # Fallback: plain Write-Host with basic ForegroundColor
    $fgMap = @{
        Debug = 'DarkGray'
        Info  = 'Cyan'
        Warn  = 'Yellow'
        Error = 'Red'
        Fatal = 'Red'
    }
    Write-Host $text -ForegroundColor $fgMap[$Level]
}

function Get-CurrentLogFilePath {
    <#
    .SYNOPSIS
        Returns the current log file path, rolling over when max size is exceeded.
    #>
    $dateStamp = Get-Date -Format 'yyyy-MM-dd'
    $baseName = "dotbot-$dateStamp"
    $basePath = Join-Path $script:LogDir "$baseName.jsonl"

    $maxBytes = $script:MaxFileSizeMB * 1MB
    if ($maxBytes -le 0 -or -not (Test-Path $basePath) -or (Get-Item $basePath).Length -lt $maxBytes) {
        return $basePath
    }

    # Find the next available rollover suffix
    for ($i = 1; $i -lt 100; $i++) {
        $rollPath = Join-Path $script:LogDir "$baseName.$i.jsonl"
        if (-not (Test-Path $rollPath) -or (Get-Item $rollPath).Length -lt $maxBytes) {
            return $rollPath
        }
    }

    return $basePath
}

function Write-JsonlLine {
    <#
    .SYNOPSIS
        Appends a single line to a JSONL file with FileStream retry logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Line
    )

    # Ensure parent directory exists
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    for ($r = 0; $r -lt $script:FileRetryCount; $r++) {
        try {
            $fs = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
            $sw.WriteLine($Line)
            $sw.Close()
            $fs.Close()
            return
        } catch {
            if ($r -lt ($script:FileRetryCount - 1)) {
                Start-Sleep -Milliseconds ($script:FileRetryBaseMs * ($r + 1))
            }
            # Final retry failure is silently ignored (non-critical logging)
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-DotBotLog',
    'Write-BotLog',
    'Rotate-DotBotLog',
    'Write-Diag'
)
