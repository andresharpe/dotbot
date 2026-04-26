function Invoke-PlanGet {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
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
        return @{
            success = $true
            has_plan = $false
            task_id = $taskId
            task_name = $task.name
            message = "No plan found for this task"
        }
    }

    # Resolve plan path (relative to project root)
    $botRoot = $global:DotbotProjectRoot
    $planFullPath = Join-Path $botRoot $task.plan_path

    if (-not (Test-Path $planFullPath)) {
        return @{
            success = $true
            has_plan = $false
            task_id = $taskId
            task_name = $task.name
            plan_path = $task.plan_path
            message = "Plan file not found at: $($task.plan_path)"
        }
    }

    # Read and return plan content
    $planContent = Get-Content $planFullPath -Raw

    return @{
        success = $true
        has_plan = $true
        task_id = $taskId
        task_name = $task.name
        plan_path = $task.plan_path
        content = $planContent
        message = "Plan retrieved for task '$($task.name)'"
    }
}
