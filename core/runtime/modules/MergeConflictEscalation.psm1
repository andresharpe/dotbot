<#
.SYNOPSIS
    Shared helper for escalating merge-conflict failures to needs-input and
    notifying external stakeholders (see issue #224).
#>

function Move-TaskToMergeConflictNeedsInput {
    <#
    .SYNOPSIS
    Move a task from done/ to needs-input/ with a merge-conflict pending_question
    and dispatch an external notification when configured.

    .PARAMETER BotRoot
    The `.bot` root directory (matches the convention used by WorktreeManager,
    Get-NotificationSettings, and the runtime process types). Defaults to
    `$global:DotbotProjectRoot/.bot`.

    .OUTPUTS
    @{ success; new_path; notified; notification_silent; notification_reason }
    notification_silent is $true when the project hasn't opted into notifications
    (no NotificationClient module or settings.enabled = $false).
    #>
    param(
        [Parameter(Mandatory)] [string] $TaskId,
        [Parameter(Mandatory)] [string] $TasksBaseDir,
        [Parameter(Mandatory)] [object] $MergeResult,
        [Parameter(Mandatory)] [string] $WorktreePath,
        [string] $BotRoot
    )

    if (-not $BotRoot) {
        if (-not $global:DotbotProjectRoot) {
            throw "Move-TaskToMergeConflictNeedsInput: BotRoot not provided and \$global:DotbotProjectRoot is not set"
        }
        $BotRoot = Join-Path $global:DotbotProjectRoot '.bot'
    }

    $doneDir = Join-Path $TasksBaseDir "done"
    $needsInputDir = Join-Path $TasksBaseDir "needs-input"

    $taskFile = Get-ChildItem -LiteralPath $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
        try {
            $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $c.id -eq $TaskId
        } catch { $false }
    } | Select-Object -First 1

    if (-not $taskFile) {
        return @{
            success             = $false
            new_path            = $null
            notified            = $false
            notification_silent = $false
            notification_reason = "Task file not found in done/"
        }
    }

    # TODO(#224): delegate to Move-TaskState once it accepts `done` as a FromState.
    $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
    $taskContent.status = 'needs-input'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("o")

    if (-not $taskContent.PSObject.Properties['pending_question']) {
        $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
    }

    $conflictFiles = @()
    if ($MergeResult -is [hashtable]) {
        if ($MergeResult.ContainsKey('conflict_files') -and $MergeResult['conflict_files']) {
            $conflictFiles = @($MergeResult['conflict_files'])
        }
    } elseif ($MergeResult.PSObject.Properties['conflict_files'] -and $MergeResult.conflict_files) {
        # Defensive only — Complete-TaskWorktree returns a [hashtable] in production.
        $conflictFiles = @($MergeResult.conflict_files)
    }
    $conflictDetail = if ($conflictFiles.Count -gt 0) { $conflictFiles -join '; ' } else { '(none reported)' }

    $taskContent.pending_question = @{
        id             = "merge-conflict"
        question       = "Merge conflict during squash-merge to main"
        context        = "Conflict details: $conflictDetail. Worktree preserved at: $WorktreePath"
        options        = @(
            @{ key = "A"; label = "Resolve manually and retry (recommended)"; rationale = "Inspect the worktree, resolve conflicts, then retry merge" }
            @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
            @{ key = "C"; label = "Retry with fresh rebase"; rationale = "Reset and attempt rebase again" }
        )
        recommendation = "A"
        asked_at       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }

    # Close the open execution session by walking the task's history. The env var
    # $env:CLAUDE_SESSION_ID is nulled by both runtime workers before the merge,
    # so we cannot rely on it. Best-effort — never block escalation.
    try {
        $sessionModule = Join-Path $BotRoot 'systems' | Join-Path -ChildPath 'mcp' | Join-Path -ChildPath 'modules' | Join-Path -ChildPath 'SessionTracking.psm1'
        if ((Test-Path $sessionModule) -and $taskContent.PSObject.Properties['execution_sessions']) {
            $openSession = @($taskContent.execution_sessions) | Where-Object {
                $_ -and $_.id -and (-not $_.ended_at)
            } | Select-Object -Last 1
            if ($openSession) {
                Import-Module $sessionModule -Force
                if (Get-Command Close-SessionOnTask -ErrorAction SilentlyContinue) {
                    Close-SessionOnTask -TaskContent $taskContent -SessionId $openSession.id -Phase 'execution'
                }
            }
        }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Merge-conflict session close failed" -Exception $_
        }
    }

    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }
    $newPath = Join-Path $needsInputDir $taskFile.Name
    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $newPath -Encoding UTF8
    try {
        Remove-Item -LiteralPath $taskFile.FullName -Force -ErrorAction Stop
    } catch {
        # Rollback: remove the newly written file to avoid split-brain (task in both done/ and needs-input/)
        Remove-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
        throw
    }

    $notified = $false
    $silent = $true
    $reason = "Notifications disabled"
    $notifModule = Join-Path $BotRoot 'systems' | Join-Path -ChildPath 'mcp' | Join-Path -ChildPath 'modules' | Join-Path -ChildPath 'NotificationClient.psm1'
    try {
        if (Test-Path $notifModule) {
            Import-Module $notifModule -Force
            # Module is present — any failure past this point is a real delivery
            # problem, NOT a silent opt-out. Flip $silent here so the catch below
            # surfaces unexpected errors instead of masking them.
            $silent = $false
            $settings = Get-NotificationSettings -BotRoot $BotRoot
            if (-not $settings.enabled) {
                # Explicit opt-out via settings.
                $silent = $true
                $reason = "Notifications disabled"
            } else {
                $sendResult = Send-TaskNotification -TaskContent $taskContent -PendingQuestion $taskContent.pending_question
                if ($sendResult -and $sendResult.success) {
                    $taskContent | Add-Member -NotePropertyName 'notification' -NotePropertyValue @{
                        question_id = $sendResult.question_id
                        instance_id = $sendResult.instance_id
                        channel     = $sendResult.channel
                        project_id  = $sendResult.project_id
                        sent_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    } -Force
                    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $newPath -Encoding UTF8
                    $notified = $true
                    $reason = "Notification dispatched"
                } else {
                    $reason = if ($sendResult -and $sendResult.reason) { $sendResult.reason } else { "Send-TaskNotification failed" }
                }
            }
        } else {
            $reason = "NotificationClient module not found"
        }
    } catch {
        $reason = "Notification error: $($_.Exception.Message)"
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Merge-conflict notification failed" -Exception $_
        }
    }

    return @{
        success             = $true
        new_path            = $newPath
        notified            = $notified
        notification_silent = $silent
        notification_reason = $reason
    }
}

function Invoke-MergeConflictEscalation {
    <#
    .SYNOPSIS
    Runtime-side wrapper around Move-TaskToMergeConflictNeedsInput. Owns
    Write-Status / Write-ProcessActivity emission so each caller collapses
    to a single call.
    #>
    param(
        [Parameter(Mandatory)] [object] $Task,
        [Parameter(Mandatory)] [string] $TasksBaseDir,
        [Parameter(Mandatory)] [object] $MergeResult,
        [Parameter(Mandatory)] [string] $WorktreePath,
        [string] $ProcId,
        [string] $BotRoot
    )

    if (-not $BotRoot) {
        if (-not $global:DotbotProjectRoot) {
            throw "Invoke-MergeConflictEscalation: BotRoot not provided and \$global:DotbotProjectRoot is not set"
        }
        $BotRoot = Join-Path $global:DotbotProjectRoot '.bot'
    }

    $emitActivity = {
        param($message)
        if ($ProcId -and (Get-Command Write-ProcessActivity -ErrorAction SilentlyContinue)) {
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message $message
        }
    }

    $escalation = $null
    try {
        $escalation = Move-TaskToMergeConflictNeedsInput `
            -TaskId $Task.id `
            -TasksBaseDir $TasksBaseDir `
            -MergeResult $MergeResult `
            -WorktreePath $WorktreePath `
            -BotRoot $BotRoot
    } catch {
        $msg = "Merge-conflict escalation helper failed: $($_.Exception.Message)"
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status $msg -Type Error
        }
        & $emitActivity "Escalation helper threw for $($Task.name): $($_.Exception.Message)"
        return @{
            success             = $false
            notified            = $false
            notification_silent = $false
            notification_reason = $msg
        }
    }

    if ($escalation -and $escalation.success) {
        $statusMsg = if ($escalation.notified) {
            "Task moved to needs-input for manual conflict resolution (stakeholders notified)"
        } else {
            "Task moved to needs-input for manual conflict resolution"
        }
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status $statusMsg -Type Warn
        }
        & $emitActivity "Escalated merge conflict for $($Task.name); notified=$($escalation.notified)"

        # Surface real delivery failures; opt-out states stay quiet.
        if (-not $escalation.notified -and -not $escalation.notification_silent) {
            if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
                Write-Status "Merge-conflict notification not delivered: $($escalation.notification_reason)" -Type Warn
            }
            & $emitActivity "Merge-conflict notification skipped for $($Task.name): $($escalation.notification_reason)"
        }
    } elseif ($escalation) {
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status "Failed to escalate merge conflict: $($escalation.notification_reason)" -Type Error
        }
        & $emitActivity "Failed to escalate merge conflict for $($Task.name): $($escalation.notification_reason)"
    } else {
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status "Merge-conflict escalation helper returned no result for $($Task.name)" -Type Error
        }
        & $emitActivity "Merge-conflict escalation helper returned null for $($Task.name)"
        $escalation = @{
            success             = $false
            notified            = $false
            notification_silent = $false
            notification_reason = "Helper returned no result"
        }
    }

    return $escalation
}

Export-ModuleMember -Function 'Move-TaskToMergeConflictNeedsInput', 'Invoke-MergeConflictEscalation'
