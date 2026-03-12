# Import session tracking module
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

# Import path sanitizer for stripping absolute paths from activity logs
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\PathSanitizer.psm1") -Force

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

        # Build a human-readable detail string from failed scripts
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
        # Non-fatal — logging failure must never block the MCP tool response
    }
}

# Helper function to extract execution-phase activity logs
function Get-ExecutionActivityLog {
    param(
        [string]$TaskId,
        [string]$ProjectRoot
    )

    # Control directory: .bot/.control (script is at .bot/systems/mcp/tools/task-mark-done)
    $controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $activityFile = Join-Path $controlDir "activity.jsonl"

    if (-not (Test-Path $activityFile)) { return @() }

    # Extract entries for this task with phase='execution' (or null for backward compat)
    $taskActivities = @()
    Get-Content $activityFile | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            # Match task_id AND (phase is 'execution' OR phase is null/missing for backward compat)
            if ($entry.task_id -eq $TaskId -and (-not $entry.phase -or $entry.phase -eq 'execution')) {
                # Sanitize absolute paths from message (defense-in-depth for pre-existing logs)
                $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $ProjectRoot
                $sanitizedEntry = $entry | Select-Object -Property type, timestamp
                $sanitizedEntry | Add-Member -NotePropertyName 'message' -NotePropertyValue $sanitizedMessage -Force
                $taskActivities += $sanitizedEntry
            }
        } catch { }
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
    
    # If no verification configured, allow marking done
    if (-not (Test-Path $configPath)) {
        return @{
            AllPassed = $true
            Scripts = @()
        }
    }
    
    # Read configuration
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $results = @()
    
    foreach ($scriptConfig in $config.scripts) {
        $scriptPath = Join-Path $scriptsDir $scriptConfig.name
        
        # Check if script exists
        if (-not (Test-Path $scriptPath)) {
            $results += @{
                success = $false
                script = $scriptConfig.name
                message = "Script file not found"
            }
            continue
        }
        
        # Check if should skip based on category
        if ($scriptConfig.skip_if_category -and $scriptConfig.skip_if_category -contains $Category) {
            $results += @{
                success = $true
                script = $scriptConfig.name
                message = "Skipped (category: $Category)"
                skipped = $true
            }
            continue
        }
        
        # Check if should only run for specific categories
        if ($scriptConfig.run_if_category -and $scriptConfig.run_if_category -notcontains $Category) {
            $results += @{
                success = $true
                script = $scriptConfig.name
                message = "Skipped (not applicable for category: $Category)"
                skipped = $true
            }
            continue
        }
        
        # Execute script and capture JSON output
        try {
            # Use provided project root
            if (-not $ProjectRoot) {
                throw "Project root parameter is required"
            }
            
            if (-not (Test-Path $ProjectRoot)) {
                throw "Project root directory does not exist: $ProjectRoot"
            }
            
            if (-not (Test-Path (Join-Path $ProjectRoot ".git"))) {
                throw "Project root does not contain .git folder: $ProjectRoot"
            }
            
            Push-Location $ProjectRoot
            
            try {
                $output = & $scriptPath -TaskId $TaskId -Category $Category 2>&1
                $result = $output | ConvertFrom-Json -ErrorAction Stop
                $results += $result
            } finally {
                Pop-Location
            }
            
            # Stop on required failure
            if ($scriptConfig.required -and -not $result.success) {
                break
            }
        } catch {
            # Script failed to execute or return valid JSON
            $results += @{
                success = $false
                script = $scriptConfig.name
                message = "Script execution failed: $($_.Exception.Message)"
                details = @{ error = $_.Exception.Message }
            }
            
            if ($scriptConfig.required) {
                break
            }
        }
    }
    
    # Determine if all passed
    $failedScripts = $results | Where-Object { $_.success -eq $false -and -not $_.skipped }
    $allPassed = $failedScripts.Count -eq 0
    
    return @{
        AllPassed = $allPassed
        Scripts = $results
    }
}

function Invoke-TaskMarkDone {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $taskId = $Arguments['task_id']
    $toStatus = 'done'
    
    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    # Use auto-detected project root (from global scope set by MCP server)
    $projectRoot = $global:DotbotProjectRoot
    
    # Validation: ensure project root is available
    if (-not $projectRoot) {
        throw "Project root not available. MCP server may not have initialized correctly."
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    [Console]::Error.WriteLine("[task-mark-done] tasksBaseDir=$tasksBaseDir exists=$(Test-Path $tasksBaseDir)")
    $todosDir = Join-Path $tasksBaseDir "todo"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
    $doneDir = Join-Path $tasksBaseDir "done"
    
    # Map status to directory
    $statusDirs = @{
        'todo' = $todosDir
        'in-progress' = $inProgressDir
        'done' = $doneDir
    }
    
    # Find the task file
    $taskFile = $null
    $currentStatus = $null
    $validStatuses = @('todo', 'in-progress', 'done')
    
    foreach ($status in $validStatuses) {
        $dir = $statusDirs[$status]
        if (Test-Path $dir) {
            $files = Get-ChildItem -Path $dir -Filter "*.json" -File
            foreach ($file in $files) {
                try {
                    $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                    if ($content.id -eq $taskId) {
                        $taskFile = $file
                        $currentStatus = $status
                        break
                    }
                } catch {
                    # Continue searching
                }
            }
            if ($taskFile) { break }
        }
    }
    
    if (-not $taskFile) {
        Write-TaskMarkDoneFailure -TaskId $taskId -Message "task_mark_done failed: task '$taskId' not found in todo/, in-progress/, or done/"
        throw "Task with ID '$taskId' not found"
    }
    
    # Check if already done
    if ($currentStatus -eq 'done') {
        return @{
            success = $true
            message = "Task is already marked as done"
            task_id = $taskId
            status = 'done'
        }
    }
    
    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
    
    # NEW: Run verification scripts
    $verificationResults = Invoke-VerificationScripts -TaskId $taskId -Category $taskContent.category -ProjectRoot $projectRoot
    
    if (-not $verificationResults.AllPassed) {
        # Log to activity stream so the operator can see the failure in the dashboard
        Write-TaskMarkDoneFailure -TaskId $taskId -Message "task_mark_done blocked: verification failed for '$($taskContent.name)'" -VerificationResults $verificationResults.Scripts

        # Verification failed - return error with details
        return @{
            success = $false
            message = "Task verification failed - task stays in '$currentStatus'"
            task_id = $taskId
            current_status = $currentStatus
            verification_passed = $false
            verification_results = $verificationResults.Scripts
        }
    }

    # Extract commit information for this task
    $commitInfo = $null
    try {
        # Import the commit extraction module
        $modulePath = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\Extract-CommitInfo.ps1"
        if (Test-Path $modulePath) {
            . $modulePath
            $commits = Get-TaskCommitInfo -TaskId $taskId -ProjectRoot $projectRoot

            if ($commits -and $commits.Count -gt 0) {
                $commitInfo = @{
                    commits = $commits
                    # Top-level fields show most recent commit
                    most_recent = $commits[0]
                }
            }
        }
    }
    catch {
        # Commit extraction failure is non-fatal - task still completes
        Write-Warning "Failed to extract commit info: $($_.Exception.Message)"
    }

    # Update task properties
    $taskContent.status = 'done'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Set completed_at timestamp
    if (-not $taskContent.completed_at) {
        $taskContent.completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }

    # Close current Claude session (execution complete)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase 'execution'
    }

    # Add commit information if found
    if ($commitInfo -and $commitInfo.most_recent) {
        $mostRecent = $commitInfo.most_recent
        $taskContent | Add-Member -NotePropertyName 'commit_sha' -NotePropertyValue $mostRecent.commit_sha -Force
        $taskContent | Add-Member -NotePropertyName 'commit_subject' -NotePropertyValue $mostRecent.commit_subject -Force
        $taskContent | Add-Member -NotePropertyName 'files_created' -NotePropertyValue $mostRecent.files_created -Force
        $taskContent | Add-Member -NotePropertyName 'files_deleted' -NotePropertyValue $mostRecent.files_deleted -Force
        $taskContent | Add-Member -NotePropertyName 'files_modified' -NotePropertyValue $mostRecent.files_modified -Force
        $taskContent | Add-Member -NotePropertyName 'commits' -NotePropertyValue $commitInfo.commits -Force
    }

    # Capture execution-phase activity log
    $executionActivities = Get-ExecutionActivityLog -TaskId $taskId -ProjectRoot $projectRoot
    if ($executionActivities.Count -gt 0) {
        $taskContent | Add-Member -NotePropertyName 'execution_activity_log' -NotePropertyValue $executionActivities -Force
    }
    
    # Ensure done directory exists
    $targetDir = $doneDir
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }
    
    # Define new file path
    $newFilePath = Join-Path $targetDir $taskFile.Name
    
    # Save updated task to new location
    $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $newFilePath -Encoding UTF8
    
    # Remove old file
    Remove-Item -Path $taskFile.FullName -Force
    
    # Return result
    return @{
        success = $true
        message = "Task marked as done"
        task_id = $taskId
        old_status = $currentStatus
        new_status = 'done'
        old_path = $taskFile.FullName
        new_path = $newFilePath
        verification_passed = $true
        verification_results = $verificationResults.Scripts
    }
}
