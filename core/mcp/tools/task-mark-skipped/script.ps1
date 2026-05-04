Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force
# Single source of truth for skip-reason classification (issue #318) lives in
# TaskIndexCache.psm1. Do NOT inline the reason lists here — keep this file
# free of duplication so adding/removing a reason only touches one place.
if (-not (Get-Module TaskIndexCache)) {
    Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskIndexCache.psm1") -DisableNameChecking
}

function Test-IsIntentionalSkipReason {
    param([string]$Reason)
    return $Reason -in (Get-IntentionalSkipReasons)
}

function Invoke-TaskMarkSkipped {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $skipReason = $Arguments['skip_reason']
    $skipDetail = $Arguments['skip_detail']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $skipReason) { throw "Skip reason is required" }

    $validReasons = (Get-IntentionalSkipReasons) + (Get-FrameworkSkipReasons)
    if ($skipReason -notin $validReasons) {
        throw "Invalid skip reason. Must be one of: $($validReasons -join ', ')"
    }

    # We need to read the task first to build skip_history, because Set-TaskState
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

    $skipEntry = [ordered]@{
        skipped_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        reason     = $skipReason
    }
    if ($skipDetail) { $skipEntry.detail = $skipDetail }
    $skipHistory += [pscustomobject]$skipEntry

    $allStatuses = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped', 'split', 'cancelled')

    $result = Set-TaskState -TaskId $taskId `
        -FromStates $allStatuses `
        -ToState 'skipped' `
        -Updates @{ skip_history = $skipHistory }

    # If already in skipped state, Set-TaskState returns early without applying updates.
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
        intentional  = (Test-IsIntentionalSkipReason -Reason $skipReason)
        file_path    = $result.file_path
    }
}
