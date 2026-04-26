# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\PathSanitizer.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

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

# Helper function to extract execution-phase activity logs
function Get-ExecutionActivityLog {
    param(
        [string]$TaskId,
        [string]$ProjectRoot
    )

    $controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $activityFile = Join-Path $controlDir "activity.jsonl"

    if (-not (Test-Path $activityFile)) { return @() }

    $taskActivities = @()
    Get-Content $activityFile | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            if ($entry.task_id -eq $TaskId -and (-not $entry.phase -or $entry.phase -eq 'execution')) {
                $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $ProjectRoot
                $sanitizedEntry = $entry | Select-Object -Property type, timestamp
                $sanitizedEntry | Add-Member -NotePropertyName 'message' -NotePropertyValue $sanitizedMessage -Force
                $taskActivities += $sanitizedEntry
            }
        } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to remove item" -Exception $_ }
    }

    return $taskActivities
}

function Invoke-VerificationScripts {
    param(
        [string]$TaskId,
        [string]$Category,
        [string]$ProjectRoot
    )

    $scriptsDir = Join-Path $global:DotbotProjectRoot ".bot\hooks\verify"
    $configPath = Join-Path $scriptsDir "config.json"

    if (-not (Test-Path $configPath)) {
        return @{ AllPassed = $true; Scripts = @() }
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $results = @()

    foreach ($scriptConfig in $config.scripts) {
        $scriptPath = Join-Path $scriptsDir $scriptConfig.name

        if (-not (Test-Path $scriptPath)) {
            $results += @{ success = $false; script = $scriptConfig.name; message = "Script file not found" }
            continue
        }

        if ($scriptConfig.skip_if_category -and $scriptConfig.skip_if_category -contains $Category) {
            $results += @{ success = $true; script = $scriptConfig.name; message = "Skipped (category: $Category)"; skipped = $true }
            continue
        }

        if ($scriptConfig.run_if_category -and $scriptConfig.run_if_category -notcontains $Category) {
            $results += @{ success = $true; script = $scriptConfig.name; message = "Skipped (not applicable for category: $Category)"; skipped = $true }
            continue
        }

        try {
            if (-not $ProjectRoot) { throw "Project root parameter is required" }
            if (-not (Test-Path $ProjectRoot)) { throw "Project root directory does not exist: $ProjectRoot" }
            if (-not (Test-Path (Join-Path $ProjectRoot ".git"))) { throw "Project root does not contain .git folder: $ProjectRoot" }

            Push-Location $ProjectRoot
            try {
                $output = & $scriptPath -TaskId $TaskId -Category $Category 2>&1
                $result = $output | ConvertFrom-Json -ErrorAction Stop
                $results += $result
            } finally {
                Pop-Location
            }

            if ($scriptConfig.required -and -not $result.success) { break }
        } catch {
            $results += @{
                success = $false
                script  = $scriptConfig.name
                message = "Script execution failed: $($_.Exception.Message)"
                details = @{ error = $_.Exception.Message }
            }
            if ($scriptConfig.required) { break }
        }
    }

    $failedScripts = $results | Where-Object { $_.success -eq $false -and -not $_.skipped }
    return @{ AllPassed = ($failedScripts.Count -eq 0); Scripts = $results }
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
        $modulePath = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\Extract-CommitInfo.ps1"
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

    $result = Move-TaskState -TaskId $taskId `
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
