function Invoke-PlanCreate {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']
    $content = $Arguments['content']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }

    if (-not $content) {
        throw "Plan content is required"
    }

    # Find task file by ID (search all status directories)
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $statusDirs = @('todo', 'in-progress', 'done', 'skipped', 'cancelled')
    $taskFile = $null
    $taskFilename = $null

    foreach ($status in $statusDirs) {
        $statusDir = Join-Path $tasksBaseDir $status
        if (Test-Path $statusDir) {
            $files = Get-ChildItem -Path $statusDir -Filter "*.json" -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                $taskContent = Get-Content $file.FullName -Raw | ConvertFrom-Json
                if ($taskContent.id -eq $taskId) {
                    $taskFile = $file.FullName
                    $taskFilename = $file.Name
                    break
                }
            }
            if ($taskFile) { break }
        }
    }

    if (-not $taskFile) {
        throw "Task not found with ID: $taskId"
    }

    # Derive plan filename from task filename (replace .json with -plan.md)
    $planFilename = $taskFilename -replace '\.json$', '-plan.md'
    $plansDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\plans"

    # Ensure plans directory exists
    if (-not (Test-Path $plansDir)) {
        New-Item -ItemType Directory -Force -Path $plansDir | Out-Null
    }

    $planPath = Join-Path $plansDir $planFilename

    # Write plan content to file
    Set-Content -Path $planPath -Value $content -Encoding UTF8

    # Update task JSON to add plan_path field
    $task = Get-Content $taskFile -Raw | ConvertFrom-Json

    # Calculate relative path from task file to plan file
    $relativePlanPath = ".bot/workspace/plans/$planFilename"

    # Add or update plan_path field
    if ($task.PSObject.Properties.Name -contains 'plan_path') {
        $task.plan_path = $relativePlanPath
    } else {
        $task | Add-Member -NotePropertyName 'plan_path' -NotePropertyValue $relativePlanPath
    }

    # Update timestamp
    $task.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Save updated task
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFile -Encoding UTF8

    # Return result
    return @{
        success = $true
        task_id = $taskId
        plan_path = $relativePlanPath
        plan_filename = $planFilename
        message = "Plan created and linked to task '$($task.name)'"
    }
}
