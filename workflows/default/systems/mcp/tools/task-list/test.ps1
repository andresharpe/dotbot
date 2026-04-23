# Test task-list tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"

Reset-TestResults

$createdFiles = @()

try {
    $created = Invoke-TaskCreate -Arguments @{
        name = 'List Test Task'
        description = 'Task for list test'
        category = 'feature'
        priority = 5
    }
    $createdFiles += $created.file_path

    $result = Invoke-TaskList -Arguments @{}

    Assert-True -Name "task-list: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Expected success"

    Assert-True -Name "task-list: returns tasks array" `
        -Condition ($null -ne $result.tasks) `
        -Message "tasks is null"

    $found = $result.tasks | Where-Object { $_.id -eq $created.task_id }
    Assert-True -Name "task-list: created task appears in list" `
        -Condition (@($found).Count -gt 0) `
        -Message "Task $($created.task_id) not found in list"

    $filtered = Invoke-TaskList -Arguments @{ status = 'todo' }

    Assert-True -Name "task-list: filter by status succeeds" `
        -Condition ($filtered.success -eq $true) `
        -Message "Filtered list failed"

} finally {
    foreach ($file in $createdFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-list"
if (-not $allPassed) { exit 1 }
