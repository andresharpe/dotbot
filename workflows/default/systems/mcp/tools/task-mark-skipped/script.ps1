function Invoke-TaskMarkSkipped {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $taskId = $Arguments['task_id']
    $skipReason = $Arguments['skip_reason']
    
    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    if (-not $skipReason) {
        throw "Skip reason is required"
    }
    
    # Validate skip reason
    $validReasons = @('non-recoverable', 'max-retries')
    if ($skipReason -notin $validReasons) {
        throw "Invalid skip reason. Must be one of: $($validReasons -join ', ')"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $todosDir = Join-Path $tasksBaseDir "todo"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
    $doneDir = Join-Path $tasksBaseDir "done"
    $skippedDir = Join-Path $tasksBaseDir "skipped"
    
    # Map status to directory
    $analysingDir = Join-Path $tasksBaseDir "analysing"
    $analysedDir = Join-Path $tasksBaseDir "analysed"
    $needsInputDir = Join-Path $tasksBaseDir "needs-input"
    $splitDir = Join-Path $tasksBaseDir "split"
    $cancelledDir = Join-Path $tasksBaseDir "cancelled"

    $statusDirs = @{
        'todo' = $todosDir
        'analysing' = $analysingDir
        'needs-input' = $needsInputDir
        'analysed' = $analysedDir
        'in-progress' = $inProgressDir
        'done' = $doneDir
        'skipped' = $skippedDir
        'split' = $splitDir
        'cancelled' = $cancelledDir
    }

    # Find the task file
    $taskFile = $null
    $currentStatus = $null
    $validStatuses = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped', 'split', 'cancelled')
    
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
        throw "Task with ID '$taskId' not found"
    }
    
    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
    
    # Update task properties
    $taskContent.status = 'skipped'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    
    # Initialize skip_history if it doesn't exist
    if (-not $taskContent.PSObject.Properties['skip_history']) {
        $taskContent | Add-Member -NotePropertyName 'skip_history' -NotePropertyValue @() -Force
    }
    
    # Convert to array if it's not already
    if ($taskContent.skip_history -isnot [System.Collections.IEnumerable] -or $taskContent.skip_history -is [string]) {
        $taskContent.skip_history = @($taskContent.skip_history) | Where-Object { $_ }
    } else {
        $taskContent.skip_history = @($taskContent.skip_history)
    }
    
    # Append new skip entry
    $skipEntry = @{
        skipped_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        reason = $skipReason
    }
    $taskContent.skip_history += $skipEntry
    
    # Ensure skipped directory exists
    if (-not (Test-Path $skippedDir)) {
        New-Item -ItemType Directory -Force -Path $skippedDir | Out-Null
    }
    
    # Move file to skipped directory
    $newFilePath = Join-Path $skippedDir $taskFile.Name
    
    # Resolve paths to compare them properly
    $oldPathResolved = [System.IO.Path]::GetFullPath($taskFile.FullName)
    $newPathResolved = [System.IO.Path]::GetFullPath($newFilePath)
    
    # Save updated task to new location (if different from old path)
    if ($oldPathResolved -ne $newPathResolved) {
        $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $newFilePath -Encoding UTF8
        Remove-Item -Path $taskFile.FullName -Force
    } else {
        # Task is already in skipped directory, just update in place
        $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFile.FullName -Encoding UTF8
    }
    
    # Return result
    return @{
        success = $true
        message = "Task marked as skipped"
        task_id = $taskId
        task_name = $taskContent.name
        old_status = $currentStatus
        new_status = 'skipped'
        skip_reason = $skipReason
        skip_count = $taskContent.skip_history.Count
        skip_history = $taskContent.skip_history
        file_path = $newFilePath
    }
}
