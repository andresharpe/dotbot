# Import session tracking module
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

# Import path sanitizer for stripping absolute paths from activity logs
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\PathSanitizer.psm1") -Force

# Helper function to extract analysis-phase activity logs and attach to analysed tasks
function Get-AnalysisActivityLog {
    param(
        [string]$TaskId
    )

    # Control directory: .bot/.control (script is at .bot/systems/mcp/tools/task-mark-analysed)
    $controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $activityFile = Join-Path $controlDir "activity.jsonl"

    if (-not (Test-Path $activityFile)) { return @() }

    # Extract entries for this task with phase='analysis'
    $taskActivities = @()
    Get-Content $activityFile | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            # Match task_id AND phase is 'analysis'
            if ($entry.task_id -eq $TaskId -and $entry.phase -eq 'analysis') {
                # Sanitize absolute paths from message (defense-in-depth for pre-existing logs)
                $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $global:DotbotProjectRoot
                $sanitizedEntry = $entry | Select-Object -Property type, timestamp
                $sanitizedEntry | Add-Member -NotePropertyName 'message' -NotePropertyValue $sanitizedMessage -Force
                $taskActivities += $sanitizedEntry
            }
        } catch { }
    }

    return $taskActivities
}

function Invoke-TaskMarkAnalysed {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']
    $analysis = $Arguments['analysis']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }

    if (-not $analysis) {
        throw "Analysis data is required"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $analysingDir = Join-Path $tasksBaseDir "analysing"
    $needsInputDir = Join-Path $tasksBaseDir "needs-input"
    $analysedDir = Join-Path $tasksBaseDir "analysed"
    
    # Find the task file (can be in analysing or needs-input)
    $taskFile = $null
    $currentStatus = $null
    
    foreach ($searchDir in @($analysingDir, $needsInputDir)) {
        if (Test-Path $searchDir) {
            $files = Get-ChildItem -Path $searchDir -Filter "*.json" -File
            foreach ($file in $files) {
                try {
                    $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                    if ($content.id -eq $taskId) {
                        $taskFile = $file
                        $currentStatus = if ($searchDir -eq $analysingDir) { 'analysing' } else { 'needs-input' }
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
        throw "Task with ID '$taskId' not found in analysing or needs-input status"
    }
    
    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
    
    # Update task properties
    $taskContent.status = 'analysed'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    
    # Add analysis_completed_at timestamp
    if (-not $taskContent.PSObject.Properties['analysis_completed_at']) {
        $taskContent | Add-Member -NotePropertyName 'analysis_completed_at' -NotePropertyValue $null -Force
    }
    $taskContent.analysis_completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Close current Claude session (analysis complete)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase 'analysis'
    }

    # Add analysed_by field
    if (-not $taskContent.PSObject.Properties['analysed_by']) {
        $taskContent | Add-Member -NotePropertyName 'analysed_by' -NotePropertyValue $null -Force
    }
    $taskContent.analysed_by = $env:CLAUDE_MODEL
    if (-not $taskContent.analysed_by) {
        $taskContent.analysed_by = 'unknown'
    }
    
    # Store analysis data
    if (-not $taskContent.PSObject.Properties['analysis']) {
        $taskContent | Add-Member -NotePropertyName 'analysis' -NotePropertyValue $null -Force
    }
    
    # Add analysed_at to the analysis object
    $analysisWithTimestamp = $analysis.Clone()
    $analysisWithTimestamp['analysed_at'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $analysisWithTimestamp['analysed_by'] = $taskContent.analysed_by

    # Capture analysis-phase activity log
    $analysisActivities = Get-AnalysisActivityLog -TaskId $taskId
    if ($analysisActivities.Count -gt 0) {
        $analysisWithTimestamp['analysis_activity_log'] = $analysisActivities
    }

    $taskContent.analysis = $analysisWithTimestamp
    
    # Clear any pending questions (they should have been resolved)
    if ($taskContent.PSObject.Properties['pending_question']) {
        $taskContent.pending_question = $null
    }
    
    # Ensure analysed directory exists
    if (-not (Test-Path $analysedDir)) {
        New-Item -ItemType Directory -Force -Path $analysedDir | Out-Null
    }
    
    # Move file to analysed directory
    $newFilePath = Join-Path $analysedDir $taskFile.Name
    
    # Save updated task to new location
    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
    Remove-Item -Path $taskFile.FullName -Force
    
    # Return result
    return @{
        success = $true
        message = "Task marked as analysed and ready for implementation"
        task_id = $taskId
        task_name = $taskContent.name
        old_status = $currentStatus
        new_status = 'analysed'
        analysis_completed_at = $taskContent.analysis_completed_at
        file_path = $newFilePath
    }
}
