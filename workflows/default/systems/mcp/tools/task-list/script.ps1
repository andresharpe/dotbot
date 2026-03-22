# Import task index module
$indexModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskIndexCache.psm1"
if (-not (Get-Module TaskIndexCache)) {
    Import-Module $indexModule -Force
}

# Initialize index on first use
$tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
[Console]::Error.WriteLine("[task-list] tasksBaseDir=$tasksBaseDir exists=$(Test-Path $tasksBaseDir)")
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

function Invoke-TaskList {
    param(
        [hashtable]$Arguments
    )

    # Extract filter arguments
    $status = $Arguments['status']
    $category = $Arguments['category']
    $minPriority = $Arguments['min_priority']
    $maxPriority = $Arguments['max_priority']
    $effort = $Arguments['effort']
    $limit = $Arguments['limit']
    $verbose = $Arguments['verbose'] -eq $true

    Write-Verbose "[task-list] Using cached task index"

    # Get tasks using cached index with filters
    $allTasks = Get-AllTasks -Status $status -Category $category -Effort $effort -MinPriority $minPriority -MaxPriority $maxPriority -Limit $limit

    # Add status to each task based on which collection it came from
    $index = Get-TaskIndex
    $sortedTasks = @()

    foreach ($task in $allTasks) {
        $taskStatus = 'unknown'
        if ($index.Todo.ContainsKey($task.id)) {
            $taskStatus = 'todo'
        } elseif ($index.Analysing.ContainsKey($task.id)) {
            $taskStatus = 'analysing'
        } elseif ($index.NeedsInput.ContainsKey($task.id)) {
            $taskStatus = 'needs-input'
        } elseif ($index.Analysed.ContainsKey($task.id)) {
            $taskStatus = 'analysed'
        } elseif ($index.InProgress.ContainsKey($task.id)) {
            $taskStatus = 'in-progress'
        } elseif ($index.Done.ContainsKey($task.id)) {
            $taskStatus = 'done'
        } elseif ($index.Split.ContainsKey($task.id)) {
            $taskStatus = 'split'
        } elseif ($index.Skipped.ContainsKey($task.id)) {
            $taskStatus = 'skipped'
        } elseif ($index.Cancelled.ContainsKey($task.id)) {
            $taskStatus = 'cancelled'
        }

        if ($verbose) {
            $sortedTasks += @{
                id = $task.id
                name = $task.name
                status = $taskStatus
                priority = $task.priority
                effort = $task.effort
                category = $task.category
                description = $task.description
                dependencies = $task.dependencies
                acceptance_criteria = $task.acceptance_criteria
                steps = $task.steps
                applicable_agents = $task.applicable_agents
                applicable_standards = $task.applicable_standards
                file_path = $task.file_path
            }
        } else {
            $sortedTasks += @{
                id = $task.id
                name = $task.name
                status = $taskStatus
                priority = $task.priority
                effort = $task.effort
                category = $task.category
            }
        }
    }

    # Prepare summary statistics
    $stats = @{
        total_count = $sortedTasks.Count
        by_status = @{}
        by_category = @{}
        by_effort = @{}
    }

    foreach ($task in $sortedTasks) {
        # Count by status
        if ($task.status) {
            if (-not $stats.by_status[$task.status]) {
                $stats.by_status[$task.status] = 0
            }
            $stats.by_status[$task.status]++
        }

        # Count by category
        if ($task.category) {
            if (-not $stats.by_category[$task.category]) {
                $stats.by_category[$task.category] = 0
            }
            $stats.by_category[$task.category]++
        }

        # Count by effort
        if ($task.effort) {
            if (-not $stats.by_effort[$task.effort]) {
                $stats.by_effort[$task.effort] = 0
            }
            $stats.by_effort[$task.effort]++
        }
    }

    # Return result
    return @{
        success = $true
        tasks = $sortedTasks
        stats = $stats
        filters_applied = @{
            status = $status
            category = $category
            min_priority = $minPriority
            max_priority = $maxPriority
            effort = $effort
            limit = $limit
        }
    }
}
