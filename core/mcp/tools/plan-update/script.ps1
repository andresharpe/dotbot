function Invoke-PlanUpdate {
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
    $task = $null

    foreach ($status in $statusDirs) {
        $statusDir = Join-Path $tasksBaseDir $status
        if (Test-Path $statusDir) {
            $files = Get-ChildItem -Path $statusDir -Filter "*.json" -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                $taskContent = Get-Content $file.FullName -Raw | ConvertFrom-Json
                if ($taskContent.id -eq $taskId) {
                    $taskFile = $file.FullName
                    $task = $taskContent
                    break
                }
            }
            if ($taskFile) { break }
        }
    }

    if (-not $taskFile) {
        throw "Task not found with ID: $taskId"
    }

    # Check if task has plan_path field
    if (-not $task.plan_path) {
        throw "Task does not have a linked plan. Use plan_create to create one first."
    }

    # Resolve plan path (relative to project root)
    $botRoot = $global:DotbotProjectRoot
    $planFullPath = Join-Path $botRoot $task.plan_path

    if (-not (Test-Path $planFullPath)) {
        throw "Plan file not found at: $($task.plan_path). Use plan_create to create a new plan."
    }

    # Overwrite plan file with new content
    Set-Content -Path $planFullPath -Value $content -Encoding UTF8

    # Update task timestamp
    $task.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFile -Encoding UTF8

    return @{
        success = $true
        task_id = $taskId
        task_name = $task.name
        plan_path = $task.plan_path
        message = "Plan updated for task '$($task.name)'"
    }
}
