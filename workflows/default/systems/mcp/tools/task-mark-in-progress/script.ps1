# Import session tracking module
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

function Invoke-TaskMarkInProgress {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $todosDir = Join-Path $tasksBaseDir "todo"
    $analysedDir = Join-Path $tasksBaseDir "analysed"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
    
    # Find the task in todo or analysed directory (analysed takes priority as it has pre-flight context)
    $taskFile = $null
    $sourceDir = $null
    
    # Check analysed first (pre-flight ready tasks)
    if (Test-Path $analysedDir) {
        $files = Get-ChildItem -Path $analysedDir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    $taskFile = $file
                    $taskContent = $content
                    $sourceDir = "analysed"
                    break
                }
            } catch {
                # Continue searching
            }
        }
    }
    
    # Then check todo (legacy tasks without pre-flight analysis)
    if (-not $taskFile -and (Test-Path $todosDir)) {
        $files = Get-ChildItem -Path $todosDir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    $taskFile = $file
                    $taskContent = $content
                    $sourceDir = "todo"
                    break
                }
            } catch {
                # Continue searching
            }
        }
    }
    
    if (-not $taskFile) {
        # Check if already in progress
        if (Test-Path $inProgressDir) {
            $files = Get-ChildItem -Path $inProgressDir -Filter "*.json" -File
            foreach ($file in $files) {
                try {
                    $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                    if ($content.id -eq $taskId) {
                        return @{
                            success = $true
                            message = "Task '$($content.name)' is already marked as in-progress"
                            task_id = $taskId
                            status = "in-progress"
                        }
                    }
                } catch {}
            }
        }

        # Check if already completed (in done folder)
        $doneDir = Join-Path $tasksBaseDir "done"
        if (Test-Path $doneDir) {
            $files = Get-ChildItem -Path $doneDir -Filter "*.json" -File
            foreach ($file in $files) {
                try {
                    $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                    if ($content.id -eq $taskId) {
                        return @{
                            success = $true
                            message = "Task '$($content.name)' is already completed"
                            task_id = $taskId
                            status = "done"
                            already_completed = $true
                        }
                    }
                } catch {}
            }
        }

        throw "Task with ID '$taskId' not found in todo or analysed folders"
    }
    
    # Update task properties
    $taskContent.status = "in-progress"
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    if (-not $taskContent.started_at) {
        $taskContent | Add-Member -NotePropertyName 'started_at' -NotePropertyValue (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") -Force
    }

    # Track Claude session for execution phase
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Add-SessionToTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase 'execution'
    }
    
    # Ensure in-progress directory exists
    if (-not (Test-Path $inProgressDir)) {
        New-Item -ItemType Directory -Force -Path $inProgressDir | Out-Null
    }
    
    # Move file to in-progress directory
    $newFilePath = Join-Path $inProgressDir $taskFile.Name
    
    # Save updated task to new location
    $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $newFilePath -Encoding UTF8
    
    # Remove old file from todo
    Remove-Item -Path $taskFile.FullName -Force
    
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
        } catch {}
    }
    
    # Return result
    return @{
        success = $true
        message = "Task '$($taskContent.name)' marked as in-progress"
        task_id = $taskId
        task_name = $taskContent.name
        old_status = $sourceDir
        new_status = "in-progress"
        file_path = $newFilePath
        has_analysis = ($sourceDir -eq "analysed")
    }
}
