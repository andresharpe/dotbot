function Invoke-TaskMarkTodo {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $taskId = $Arguments['task_id']
    $toStatus = 'todo'
    
    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $todosDir = Join-Path $tasksBaseDir "todo"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
    $doneDir = Join-Path $tasksBaseDir "done"
    $skippedDir = Join-Path $tasksBaseDir "skipped"

    # Map status to directory
    $statusDirs = @{
        'todo' = $todosDir
        'in-progress' = $inProgressDir
        'done' = $doneDir
        'skipped' = $skippedDir
    }

    # Find the task file
    $taskFile = $null
    $currentStatus = $null
    $validStatuses = @('todo', 'in-progress', 'done', 'skipped')
    
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
    
    # Check if already todo
    if ($currentStatus -eq 'todo') {
        return @{
            success = $true
            message = "Task is already marked as todo"
            task_id = $taskId
            status = 'todo'
        }
    }
    
    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
    
    # Update task properties
    $taskContent.status = 'todo'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    
    # Clear completion timestamps when reverting to todo
    $taskContent.completed_at = $null
    if ($taskContent.PSObject.Properties['started_at']) {
        $taskContent.started_at = $null
    }
    
    # Ensure todo directory exists
    $targetDir = $todosDir
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
        message = "Task marked as todo"
        task_id = $taskId
        old_status = $currentStatus
        new_status = 'todo'
        old_path = $taskFile.FullName
        new_path = $newFilePath
    }
}
