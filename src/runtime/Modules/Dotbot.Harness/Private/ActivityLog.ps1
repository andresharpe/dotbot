<#
.SYNOPSIS
Activity log writer for the dotbot UI's oscilloscope and per-process logs.

.DESCRIPTION
Write-ActivityLog appends a structured event to .control/activity.jsonl and the
per-process .control/processes/<id>.activity.jsonl. When Dotbot.Logging is loaded
it delegates to Write-BotLog (which handles path sanitization, retry, level
mapping). Otherwise it writes directly via Add-Content with a small retry loop
to handle Windows file-share contention.

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

    # Fallback path — used only when Dotbot.Logging is not loaded (e.g. some test
    # contexts and standalone adapter calls). Keep it simple: Add-Content with
    # a short retry loop for Windows share contention.
    $controlDir = Join-Path (Get-DotbotProjectBotPath) ".control"
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    $effectivePhase = if ($Phase) { $Phase } elseif ($env:DOTBOT_CURRENT_PHASE) { $env:DOTBOT_CURRENT_PHASE } else { $null }
    $sanitizedMessage = Remove-AbsolutePaths -Text $Message -ProjectRoot $global:DotbotProjectRoot

    $event = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type      = $Type
        message   = $sanitizedMessage
        task_id   = $env:DOTBOT_CURRENT_TASK_ID
        phase     = $effectivePhase
    } | ConvertTo-Json -Compress

    $targets = @(Join-Path $controlDir "activity.jsonl")
    $procId = $env:DOTBOT_PROCESS_ID
    if ($procId) {
        $targets += Join-Path (Join-Path $controlDir "processes") "$procId.activity.jsonl"
    }

    foreach ($path in $targets) {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        for ($r = 0; $r -lt 3; $r++) {
            try {
                Add-Content -LiteralPath $path -Value $event -Encoding utf8NoBOM -ErrorAction Stop
                break
            } catch {
                if ($r -lt 2) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
            }
        }
    }
}
