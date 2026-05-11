# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/PathSanitizer.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force
if (-not (Get-Module ActivityLog)) {
    Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/ActivityLog.psm1") -DisableNameChecking -Global
}

# Helper: append a diagnostic entry to the shared activity log so the operator
# can see task_mark_done failures in the dashboard activity stream.
function Write-TaskMarkDoneFailure {
    param(
        [string]$TaskId,
        [string]$Message,
        [array]$VerificationResults = @()
    )

    try {
        $controlDir  = Join-Path $global:DotbotProjectRoot ".bot\.control"
        $activityFile = Join-Path $controlDir "activity.jsonl"
        if (-not (Test-Path $controlDir)) { return }

        $failedScripts = @($VerificationResults | Where-Object { $_.success -eq $false -and -not $_.skipped })
        if ($failedScripts.Count -gt 0) {
            $detail = ($failedScripts | ForEach-Object {
                $failLines = if ($_.failures) {
                    ($_.failures | ForEach-Object { $_.issue }) -join '; '
                } else { $_.message }
                "$($_.script): $failLines"
            }) -join ' | '
            $Message = "$Message — $detail"
        }

        $entry = [ordered]@{
            type       = "text"
            timestamp  = (Get-Date).ToUniversalTime().ToString("o")
            message    = $Message
            task_id    = $TaskId
            phase      = "execution"
            process_id = $env:DOTBOT_PROCESS_ID
        }
        ($entry | ConvertTo-Json -Compress) | Add-Content -Path $activityFile -Encoding UTF8
    } catch {
        # Non-fatal
    }
}


function Invoke-TaskMarkDone {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    $projectRoot = $global:DotbotProjectRoot
    if (-not $projectRoot) { throw "Project root not available. MCP server may not have initialized correctly." }

    # Pre-read the task to run verification before the transition
    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('todo', 'analysing', 'analysed', 'in-progress', 'done')
    if (-not $found) {
        Write-TaskMarkDoneFailure -TaskId $taskId -Message "task_mark_done failed: task '$taskId' not found in todo/, analysing/, analysed/, in-progress/, or done/"
        throw "Task with ID '$taskId' not found"
    }

    # Already done — idempotent
    if ($found.Status -eq 'done') {
        return @{ success = $true; message = "Task is already marked as done"; task_id = $taskId; status = 'done' }
    }

    $taskContent = $found.Content

    # Enforce human-review gate: agent must not bypass task_mark_needs_review
    if ($taskContent.needs_review -eq $true -and $found.Status -ne 'needs-review') {
        return @{
            success = $false
            error   = "Task '$taskId' requires human review (needs_review=true). Call task_mark_needs_review instead of task_mark_done."
        }
    }

    # Run verification scripts BEFORE transition
    $verificationResults = Invoke-VerificationScripts -TaskId $taskId -Category $taskContent.category -ProjectRoot $projectRoot

    if (-not $verificationResults.AllPassed) {
        Write-TaskMarkDoneFailure -TaskId $taskId -Message "task_mark_done blocked: verification failed for '$($taskContent.name)'" -VerificationResults $verificationResults.Scripts
        return @{
            success              = $false
            message              = "Task verification failed - task stays in '$($found.Status)'"
            task_id              = $taskId
            current_status       = $found.Status
            verification_passed  = $false
            verification_results = $verificationResults.Scripts
        }
    }

    # Extract commit information
    $commitUpdates = @{}
    try {
        $modulePath = Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/Extract-CommitInfo.ps1"
        if (Test-Path $modulePath) {
            . $modulePath
            $commits = Get-TaskCommitInfo -TaskId $taskId -ProjectRoot $projectRoot
            if ($commits -and $commits.Count -gt 0) {
                $mostRecent = $commits[0]
                $commitUpdates['commit_sha']     = $mostRecent.commit_sha
                $commitUpdates['commit_subject'] = $mostRecent.commit_subject
                $commitUpdates['files_created']  = $mostRecent.files_created
                $commitUpdates['files_deleted']  = $mostRecent.files_deleted
                $commitUpdates['files_modified'] = $mostRecent.files_modified
                $commitUpdates['commits']        = $commits
            }
        }
    } catch {
        Write-BotLog -Level Warn -Message "Failed to extract commit info" -Exception $_
    }

    # Capture execution-phase activity log
    $executionActivities = Get-ExecutionActivityLog -TaskId $taskId -ProjectRoot $projectRoot

    # Build updates
    $updates = @{
        completed_at = if (-not $taskContent.completed_at) { (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { $taskContent.completed_at }
    }
    foreach ($key in $commitUpdates.Keys) { $updates[$key] = $commitUpdates[$key] }
    if ($executionActivities.Count -gt 0) { $updates['execution_activity_log'] = $executionActivities }

    $result = Set-TaskState -TaskId $taskId `
        -FromStates @('todo', 'analysing', 'analysed', 'in-progress', 'done') `
        -ToState 'done' `
        -Updates $updates

    # Close current Claude session (execution complete)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $result.task_content -SessionId $claudeSessionId -Phase 'execution'
        $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
    }

    return @{
        success              = $true
        message              = "Task marked as done"
        task_id              = $taskId
        old_status           = $result.old_status
        new_status           = 'done'
        old_path             = $found.File.FullName
        new_path             = $result.file_path
        verification_passed  = $true
        verification_results = $verificationResults.Scripts
    }
}


