Import-Module (Join-Path $PSScriptRoot ".." ".." "modules" "TaskPlan.psm1") -DisableNameChecking -Global

function Invoke-PlanGet {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    Get-TaskPlan -TaskId $taskId
}
