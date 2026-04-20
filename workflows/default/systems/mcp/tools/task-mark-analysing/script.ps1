# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\FrameworkIntegrity.psm1") -Force

function Invoke-TaskMarkAnalysing {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    # Framework integrity gate — closes the pre-commit bypass (--no-verify)
    # and the gitignored-.bot/ silent-pass cases before the agent starts work.
    $gate = Invoke-FrameworkIntegrityGate -ProjectRoot $global:DotbotProjectRoot -TaskId $taskId
    if ($gate) { return $gate }

    # Build updates
    $updates = @{
        analysis_started_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }

    # Perform atomic state transition
    $result = Move-TaskState -TaskId $taskId -FromStates @('todo', 'analysing') -ToState 'analysing' -Updates $updates

    # Track Claude session for conversation continuity (only on actual transition)
    if (-not $result.already_in_state) {
        $claudeSessionId = $env:CLAUDE_SESSION_ID
        if ($claudeSessionId) {
            Add-SessionToTask -TaskContent $result.task_content -SessionId $claudeSessionId -Phase 'analysis'
            # Re-save with session data
            $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
        }
    }

    return @{
        success            = $true
        message            = if ($result.already_in_state) { "Task already in analysing status" } else { "Task marked as analysing" }
        task_id            = $taskId
        task_name          = $result.task_name
        old_status         = $result.old_status
        new_status         = 'analysing'
        analysis_started_at = $result.task_content.analysis_started_at
        file_path          = $result.file_path
    }
}
