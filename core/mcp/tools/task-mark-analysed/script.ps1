# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\PathSanitizer.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

# Helper function to extract analysis-phase activity logs and attach to analysed tasks
function Get-AnalysisActivityLog {
    param(
        [string]$TaskId
    )

    $controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $activityFile = Join-Path $controlDir "activity.jsonl"

    if (-not (Test-Path $activityFile)) { return @() }

    $taskActivities = @()
    Get-Content $activityFile | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            if ($entry.task_id -eq $TaskId -and $entry.phase -eq 'analysis') {
                $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $global:DotbotProjectRoot
                $sanitizedEntry = $entry | Select-Object -Property type, timestamp
                $sanitizedEntry | Add-Member -NotePropertyName 'message' -NotePropertyValue $sanitizedMessage -Force
                $taskActivities += $sanitizedEntry
            }
        } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to remove item" -Exception $_ }
    }

    return $taskActivities
}

function Invoke-TaskMarkAnalysed {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $analysis = $Arguments['analysis']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $analysis) { throw "Analysis data is required" }

    # Determine analysed_by
    $analysedBy = $env:CLAUDE_MODEL
    if (-not $analysedBy) { $analysedBy = 'unknown' }

    # Build analysis data with timestamp
    $analysisWithTimestamp = $analysis.Clone()
    $analysisWithTimestamp['analysed_at'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $analysisWithTimestamp['analysed_by'] = $analysedBy

    # Capture analysis-phase activity log
    $analysisActivities = Get-AnalysisActivityLog -TaskId $taskId
    if ($analysisActivities.Count -gt 0) {
        $analysisWithTimestamp['analysis_activity_log'] = $analysisActivities
    }

    $updates = @{
        analysis_completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        analysed_by           = $analysedBy
        analysis              = $analysisWithTimestamp
        pending_question      = $null
    }

    $result = Move-TaskState -TaskId $taskId `
        -FromStates @('analysing', 'needs-input', 'analysed') `
        -ToState 'analysed' `
        -Updates $updates

    # If already analysed, still persist the updated analysis data
    if ($result.already_in_state) {
        $updateResult = Update-TaskRecord -TaskId $taskId -Updates $updates
        $result.task_content = $updateResult.task_content
        $result.file_path = $updateResult.file_path
    }

    # Close current Claude session (analysis complete) on actual transition
    if (-not $result.already_in_state) {
        $claudeSessionId = $env:CLAUDE_SESSION_ID
        if ($claudeSessionId) {
            Close-SessionOnTask -TaskContent $result.task_content -SessionId $claudeSessionId -Phase 'analysis'
            $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
        }
    }

    return @{
        success               = $true
        message               = "Task marked as analysed and ready for implementation"
        task_id               = $taskId
        task_name             = $result.task_name
        old_status            = $result.old_status
        new_status            = 'analysed'
        analysis_completed_at = $result.task_content.analysis_completed_at
        file_path             = $result.file_path
    }
}
