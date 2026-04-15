# Test task-get-next tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"

Reset-TestResults

$createdFiles = @()

try {
    $created = Invoke-TaskCreate -Arguments @{
        name = 'Next Task Test'
        description = 'Task for get-next test'
        category = 'feature'
        priority = 1
    }
    $createdFiles += $created.file_path

    $result = Invoke-TaskGetNext -Arguments @{}

    Assert-True -Name "task-get-next: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-True -Name "task-get-next: returns a task" `
        -Condition ($null -ne $result.task) `
        -Message "task is null"

    Assert-True -Name "task-get-next: task has id" `
        -Condition ($null -ne $result.task.id -and $result.task.id.Length -gt 0) `
        -Message "task.id is empty"

    Assert-True -Name "task-get-next: task has name" `
        -Condition ($null -ne $result.task.name -and $result.task.name.Length -gt 0) `
        -Message "task.name is empty"

} finally {
    foreach ($file in $createdFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-get-next"
if (-not $allPassed) { exit 1 }
