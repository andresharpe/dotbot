<#
.SYNOPSIS
Activity log writer for the dotbot UI's oscilloscope and per-process logs.

.DESCRIPTION
Write-ActivityLog appends a structured event to .control/activity.jsonl and the
per-process .control/processes/<id>.activity.jsonl. When Dotbot.Logging is loaded
it delegates to Write-BotLog (which handles path sanitization, retry, level
mapping). Otherwise it writes directly with a UTF-8 (no-BOM) writer and a small
retry loop to handle Windows file-share contention.

Used by every adapter to surface stream events to the UI in near-real-time.
#>

function Write-ActivityLog {
    [CmdletBinding()]
    param(
        [string]$Type,
        [string]$Message,
        [string]$Phase  # Optional: 'analysis' or 'execution'. Falls back to $env:DOTBOT_CURRENT_PHASE
    )

    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        $levelMap = @{ 'error' = 'Error'; 'warning' = 'Warn'; 'fatal' = 'Fatal' }
        $level = if ($levelMap[$Type]) { $levelMap[$Type] } else { 'Info' }
        $ctx = @{ activity_type = $Type }
        if ($Phase) { $ctx.phase_override = $Phase }

        $savedPhase = $env:DOTBOT_CURRENT_PHASE
        if ($Phase) { $env:DOTBOT_CURRENT_PHASE = $Phase }
        try {
            Write-BotLog -Level $level -Message $Message -Context $ctx
        } finally {
            if ($Phase) { $env:DOTBOT_CURRENT_PHASE = $savedPhase }
        }
        return
    }

    # Fallback: direct file write if DotbotLog not loaded
    $controlDir = Join-Path (Get-DotbotProjectBotPath) ".control"
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    $effectivePhase = if ($Phase) { $Phase } elseif ($env:DOTBOT_CURRENT_PHASE) { $env:DOTBOT_CURRENT_PHASE } else { $null }
    $sanitizedMessage = Remove-AbsolutePaths -Text $Message -ProjectRoot $global:DotbotProjectRoot

    $event = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type = $Type
        message = $sanitizedMessage
        task_id = $env:DOTBOT_CURRENT_TASK_ID
        phase = $effectivePhase
    } | ConvertTo-Json -Compress

    $logPath = Join-Path $controlDir "activity.jsonl"
    $maxRetries = 3
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
            $sw.WriteLine($event)
            $sw.Close()
            $fs.Close()
            break
        } catch {
            if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
        }
    }

    $procId = $env:DOTBOT_PROCESS_ID
    if ($procId) {
        $processLogPath = Join-Path (Join-Path $controlDir "processes") "$procId.activity.jsonl"
        for ($r = 0; $r -lt $maxRetries; $r++) {
            try {
                $fs = [System.IO.FileStream]::new($processLogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
                $sw.WriteLine($event)
                $sw.Close()
                $fs.Close()
                break
            } catch {
                if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
            }
        }
    }
}
