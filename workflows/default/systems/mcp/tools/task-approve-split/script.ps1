function Invoke-TaskApproveSplit {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $taskId = $Arguments['task_id']
    $approved = $Arguments['approved']
    
    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    if ($null -eq $approved) {
        throw "Approved flag is required (true or false)"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $needsInputDir = Join-Path $tasksBaseDir "needs-input"
    $analysingDir = Join-Path $tasksBaseDir "analysing"
    $splitDir = Join-Path $tasksBaseDir "split"
    $todoDir = Join-Path $tasksBaseDir "todo"
    
    # Find the task file in needs-input
    $taskFile = $null
    if (Test-Path $needsInputDir) {
        $files = Get-ChildItem -Path $needsInputDir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    $taskFile = $file
                    break
                }
            } catch {
                # Continue searching
            }
        }
    }
    
    if (-not $taskFile) {
        throw "Task with ID '$taskId' not found in needs-input status"
    }
    
    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
    
    # Verify there's a split proposal
    if (-not $taskContent.split_proposal) {
        throw "Task has no split proposal to approve/reject"
    }
    
    $splitProposal = $taskContent.split_proposal
    
    if (-not $approved) {
        # Rejected - move back to analysing
        $taskContent.status = 'analysing'
        $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        
        # Record rejection in split_proposal
        $taskContent.split_proposal | Add-Member -NotePropertyName 'rejected_at' -NotePropertyValue (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") -Force
        $taskContent.split_proposal | Add-Member -NotePropertyName 'status' -NotePropertyValue 'rejected' -Force
        
        # Ensure analysing directory exists
        if (-not (Test-Path $analysingDir)) {
            New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null
        }
        
        # Move file to analysing directory
        $newFilePath = Join-Path $analysingDir $taskFile.Name
        
        # Save updated task
        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
        Remove-Item -Path $taskFile.FullName -Force
        
        return @{
            success = $true
            message = "Split proposal rejected - task returned to analysis"
            task_id = $taskId
            task_name = $taskContent.name
            old_status = 'needs-input'
            new_status = 'analysing'
            approved = $false
            file_path = $newFilePath
        }
    }
    
    # Approved - create sub-tasks and move original to split/
    
    # Import task-create-bulk function
    . (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\tools\task-create-bulk\script.ps1")
    
    # Prepare sub-tasks for creation
    $subTasksToCreate = @()
    foreach ($subTask in $splitProposal.sub_tasks) {
        $subTaskDef = @{
            name = $subTask.name
            description = if ($subTask.description) { $subTask.description } else { "Sub-task of: $($taskContent.name)" }
            category = $taskContent.category
            priority = $taskContent.priority
            effort = $subTask.effort
            parent_task_id = $taskId
        }
        
        # Copy dependencies from parent if any
        if ($taskContent.dependencies -and $taskContent.dependencies.Count -gt 0) {
            $subTaskDef['dependencies'] = $taskContent.dependencies
        }
        
        $subTasksToCreate += $subTaskDef
    }
    
    # Create sub-tasks (skip if empty — e.g. duplicate/redundant task archival)
    if ($subTasksToCreate.Count -gt 0) {
        $createResult = Invoke-TaskCreateBulk -Arguments @{ tasks = $subTasksToCreate }
        if (-not $createResult.success) {
            throw "Failed to create sub-tasks: $($createResult.message)"
        }
        $childTaskIds = @($createResult.created_tasks | ForEach-Object { $_.id })
    } else {
        $childTaskIds = @()
    }
    
    # Update original task for split status
    $taskContent.status = 'split'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    
    # Add split metadata
    if (-not $taskContent.PSObject.Properties['split_at']) {
        $taskContent | Add-Member -NotePropertyName 'split_at' -NotePropertyValue $null -Force
    }
    $taskContent.split_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    
    if (-not $taskContent.PSObject.Properties['split_reason']) {
        $taskContent | Add-Member -NotePropertyName 'split_reason' -NotePropertyValue $null -Force
    }
    $taskContent.split_reason = $splitProposal.reason
    
    if (-not $taskContent.PSObject.Properties['child_tasks']) {
        $taskContent | Add-Member -NotePropertyName 'child_tasks' -NotePropertyValue @() -Force
    }
    $taskContent.child_tasks = $childTaskIds
    
    # Update split_proposal status
    $taskContent.split_proposal | Add-Member -NotePropertyName 'approved_at' -NotePropertyValue (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") -Force
    $taskContent.split_proposal | Add-Member -NotePropertyName 'status' -NotePropertyValue 'approved' -Force
    
    # Ensure split directory exists
    if (-not (Test-Path $splitDir)) {
        New-Item -ItemType Directory -Force -Path $splitDir | Out-Null
    }
    
    # Move file to split directory
    $newFilePath = Join-Path $splitDir $taskFile.Name
    
    # Save updated task
    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
    Remove-Item -Path $taskFile.FullName -Force
    
    return @{
        success = $true
        message = "Split approved - created $($childTaskIds.Count) sub-tasks"
        task_id = $taskId
        task_name = $taskContent.name
        old_status = 'needs-input'
        new_status = 'split'
        approved = $true
        child_tasks = $childTaskIds
        sub_tasks_created = $createResult.tasks_created
        file_path = $newFilePath
    }
}
