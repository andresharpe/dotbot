# ═══════════════════════════════════════════════════════════════
# enter-failed — Dotbot transition hook (PRD-06).
#
# Side effects when a task enters 'failed':
#   1. Archive the task's last-known state into a diagnostics location
#      (<BotRoot>/.control/diagnostics/failed-tasks/<id>-<utc>.json).
#   2. Emit a notification through the existing notification channel.
#   3. Fire WorkflowRun status aggregation (PRD-12).
#
# Advisory: abort_on_failure is false in metadata — the task is already in
# a failure state and reverting on hook error would lose information.
# ═══════════════════════════════════════════════════════════════

function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$FromStatus,
        [Parameter(Mandatory)][string]$ToStatus
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $botRoot = $null
        if ($RunContext.ContainsKey('BotRoot')) { $botRoot = $RunContext['BotRoot'] }

        if ($botRoot) {
            $diagDir = Join-Path $botRoot (Join-Path '.control' (Join-Path 'diagnostics' 'failed-tasks'))
            if (-not (Test-Path -LiteralPath $diagDir -PathType Container)) {
                New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
            }
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
            $archivePath = Join-Path $diagDir "$($Task['id'])-$stamp.json"
            $payload = [ordered]@{
                archived_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                from_status = $FromStatus
                to_status   = $ToStatus
                task        = $Task
            }
            $json = $payload | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($archivePath, $json, [System.Text.UTF8Encoding]::new($false))
        }

        # Notification + run aggregation are PRD-04/PRD-12 follow-ups (the
        # notification channel and run aggregator live in those PRDs).

        $sw.Stop()
        return @{
            Success  = $true
            Message  = "Task archived; notification + run aggregation are PRD-04/12 follow-ups."
            Duration = $sw.Elapsed
        }
    } catch {
        $sw.Stop()
        return @{
            Success  = $false
            Message  = "enter-failed archive failed: $($_.Exception.Message)"
            Duration = $sw.Elapsed
        }
    }
}

Export-ModuleMember -Function Invoke-Hook
