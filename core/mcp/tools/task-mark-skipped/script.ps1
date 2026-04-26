Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

function Invoke-TaskMarkSkipped {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $skipReason = $Arguments['skip_reason']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $skipReason) { throw "Skip reason is required" }

    $validReasons = @('non-recoverable', 'max-retries')
    if ($skipReason -notin $validReasons) {
        throw "Invalid skip reason. Must be one of: $($validReasons -join ', ')"
    }

    # We need to read the task first to build skip_history, because Move-TaskState
    # won't apply updates on idempotent (already_in_state) returns.
    $found = Find-TaskFileById -TaskId $taskId
    if (-not $found) { throw "Task with ID '$taskId' not found" }

    $taskContent = $found.Content

    # Build skip_history
    $skipHistory = @()
    if ($taskContent.PSObject.Properties['skip_history']) {
        if ($taskContent.skip_history -is [System.Collections.IEnumerable] -and $taskContent.skip_history -isnot [string]) {
            $skipHistory = @($taskContent.skip_history)
        } elseif ($taskContent.skip_history) {
            $skipHistory = @($taskContent.skip_history)
        }
    }

    $skipEntry = @{
        skipped_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        reason     = $skipReason
    }
    $skipHistory += $skipEntry

    $allStatuses = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped', 'split', 'cancelled')

    $result = Move-TaskState -TaskId $taskId `
        -FromStates $allStatuses `
        -ToState 'skipped' `
        -Updates @{ skip_history = $skipHistory }

    # If already in skipped state, Move-TaskState returns early without applying updates.
    # Persist skip_history manually in that case.
    if ($result.already_in_state) {
        Set-OrAddProperty -Object $result.task_content -Name 'skip_history' -Value $skipHistory
        Set-OrAddProperty -Object $result.task_content -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
    }

    return @{
        success      = $true
        message      = "Task marked as skipped"
        task_id      = $taskId
        task_name    = $result.task_name
        old_status   = $result.old_status
        new_status   = 'skipped'
        skip_reason  = $skipReason
        skip_count   = $skipHistory.Count
        skip_history = $skipHistory
        file_path    = $result.file_path
    }
}
