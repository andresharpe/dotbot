Import-Module (Join-Path $PSScriptRoot ".." ".." "modules" "TaskPlan.psm1") -DisableNameChecking -Global

function Invoke-PlanCreate {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $content = $Arguments['content']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $content) { throw "Plan content is required" }

    New-TaskPlan -TaskId $taskId -Content $content
}
