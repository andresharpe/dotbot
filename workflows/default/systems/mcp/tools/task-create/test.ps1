# Test task-create tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$createdFiles = @()

try {
    $result = Invoke-TaskCreate -Arguments @{
        name = 'Test Create Task'
        description = 'Validate task-create produces a file in todo/'
        category = 'feature'
        priority = 10
        effort = 'S'
        acceptance_criteria = @('Criterion A', 'Criterion B')
        steps = @('Step 1', 'Step 2')
    }
    $createdFiles += $result.file_path

    Assert-True -Name "task-create: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-True -Name "task-create: returns task_id" `
        -Condition ($null -ne $result.task_id -and $result.task_id.Length -gt 0) `
        -Message "task_id is empty"

    Assert-PathExists -Name "task-create: file exists on disk" `
        -Path $result.file_path

    $content = Get-Content $result.file_path -Raw | ConvertFrom-Json

    Assert-Equal -Name "task-create: name matches" `
        -Expected 'Test Create Task' `
        -Actual $content.name

    Assert-Equal -Name "task-create: status is todo" `
        -Expected 'todo' `
        -Actual $content.status

    Assert-Equal -Name "task-create: priority matches" `
        -Expected 10 `
        -Actual $content.priority

} finally {
    foreach ($file in $createdFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-create"
if (-not $allPassed) { exit 1 }
