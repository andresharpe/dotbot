# Test task-mark-todo tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"
. "$PSScriptRoot\..\task-mark-in-progress\script.ps1"

Reset-TestResults

$cleanupFiles = @()

try {
    $created = Invoke-TaskCreate -Arguments @{
        name = 'Todo Revert Test Task'
        description = 'Task for mark-todo test'
        category = 'feature'
        priority = 20
    }
    $progress = Invoke-TaskMarkInProgress -Arguments @{ task_id = $created.task_id }

    $result = Invoke-TaskMarkTodo -Arguments @{ task_id = $created.task_id }

    Assert-True -Name "task-mark-todo: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-mark-todo: new_status is todo" `
        -Expected 'todo' `
        -Actual $result.new_status

    $todoDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\todo"
    $todoFile = Get-ChildItem -Path $todoDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $created.task_id
    }
    Assert-True -Name "task-mark-todo: file moved back to todo/" `
        -Condition ($null -ne $todoFile) `
        -Message "File not found in todo/"

    if ($todoFile) { $cleanupFiles += $todoFile.FullName }

    $alreadyTodo = Invoke-TaskMarkTodo -Arguments @{ task_id = $created.task_id }

    Assert-True -Name "task-mark-todo: idempotent when already todo" `
        -Condition ($alreadyTodo.success -eq $true) `
        -Message "Already-todo failed"

} finally {
    foreach ($file in $cleanupFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-mark-todo"
if (-not $allPassed) { exit 1 }
