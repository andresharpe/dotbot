# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\FrameworkIntegrity.psm1") -Force

function Invoke-TaskMarkInProgress {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    # Framework integrity gate — closes the pre-commit bypass (--no-verify)
    # and the gitignored-.bot/ silent-pass cases before execution begins.
    $gate = Invoke-FrameworkIntegrityGate -ProjectRoot $global:DotbotProjectRoot -TaskId $taskId
    if ($gate) { return $gate }

    # Build updates — only set started_at if not already set
    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('analysed', 'todo', 'in-progress', 'done')
    if (-not $found) {
        throw "Task with ID '$taskId' not found in analysed, todo, in-progress, or done states"
    }

    # Handle already-done
    if ($found.Status -eq 'done') {
        return @{
            success           = $true
            message           = "Task '$($found.Content.name)' is already completed"
            task_id           = $taskId
            status            = "done"
            already_completed = $true
        }
    }

    # Handle already in-progress
    if ($found.Status -eq 'in-progress') {
        return @{
            success = $true
            message = "Task '$($found.Content.name)' is already marked as in-progress"
            task_id = $taskId
            status  = "in-progress"
        }
    }

    $updates = @{}
    if (-not $found.Content.started_at) {
        $updates['started_at'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }

    $result = Move-TaskState -TaskId $taskId `
        -FromStates @('analysed', 'todo', 'in-progress') `
        -ToState 'in-progress' `
        -Updates $updates

    # Track Claude session for execution phase
    if (-not $result.already_in_state) {
        $claudeSessionId = $env:CLAUDE_SESSION_ID
        if ($claudeSessionId) {
            Add-SessionToTask -TaskContent $result.task_content -SessionId $claudeSessionId -Phase 'execution'
            $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
        }
    }

    # Update session file if exists
    $sessionFile = Get-ChildItem ".bot/sessions/session-*.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime.Date -eq (Get-Date).Date } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    if ($sessionFile) {
        try {
            $session = Get-Content $sessionFile.FullName | ConvertFrom-Json
            if (-not $session.tasks_attempted) {
                $session | Add-Member -NotePropertyName 'tasks_attempted' -NotePropertyValue @() -Force
            }
            $session.tasks_attempted += $taskId
            $session | ConvertTo-Json -Depth 10 | Set-Content $sessionFile.FullName
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    return @{
        success      = $true
        message      = "Task '$($result.task_name)' marked as in-progress"
        task_id      = $taskId
        task_name    = $result.task_name
        old_status   = $result.old_status
        new_status   = "in-progress"
        file_path    = $result.file_path
        has_analysis = ($result.old_status -eq "analysed")
    }
}
