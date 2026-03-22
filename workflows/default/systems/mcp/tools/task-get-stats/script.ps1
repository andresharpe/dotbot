# Import task index module
$indexModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskIndexCache.psm1"
if (-not (Get-Module TaskIndexCache)) {
    Import-Module $indexModule -Force
}

# Initialize index on first use
$tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

function Invoke-TaskGetStats {
    param(
        [hashtable]$Arguments
    )

    Write-Verbose "[task-get-stats] Using cached task index"

    # Get stats from cached index
    $stats = Get-TaskStats
    $days_remaining = Get-RemainingEffort

    # Calculate percentages
    $percentage_complete = if ($stats.total -gt 0) {
        [Math]::Round(($stats.done / $stats.total) * 100, 1)
    } else { 0 }

    $percentage_in_progress = if ($stats.total -gt 0) {
        [Math]::Round(($stats.in_progress / $stats.total) * 100, 1)
    } else { 0 }

    # Build summary message
    $summary = "Tasks: $($stats.done)/$($stats.total) complete ($percentage_complete%)"
    if ($stats.in_progress -gt 0) {
        $summary += ", $($stats.in_progress) in progress"
    }

    # Return comprehensive statistics
    return @{
        success = $true
        total_tasks = $stats.total
        passing = $stats.done
        in_progress = $stats.in_progress
        todo = $stats.todo
        percentage_complete = $percentage_complete
        percentage_in_progress = $percentage_in_progress
        days_effort_remaining = $days_remaining
        by_category = $stats.by_category
        by_effort = $stats.by_effort
        by_priority = $stats.by_priority_range
        summary = $summary
        message = if ($stats.total -eq 0) {
            "No tasks found. Run 'plan-roadmap' to create tasks."
        } else {
            $summary
        }
    }
}
