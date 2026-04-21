# Test task-create-bulk tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"

Reset-TestResults

$createdFiles = @()

try {
    $result = Invoke-TaskCreateBulk -Arguments @{
        tasks = @(
            @{
                name = 'Bulk Task A'
                description = 'First bulk task'
                category = 'feature'
                effort = 'S'
            },
            @{
                name = 'Bulk Task B'
                description = 'Second bulk task'
                category = 'feature'
                effort = 'M'
            }
        )
    }
    foreach ($task in $result.created_tasks) {
        $createdFiles += $task.file_path
    }

    Assert-True -Name "task-create-bulk: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-create-bulk: created_count is 2" `
        -Expected 2 `
        -Actual $result.created_count

    Assert-Equal -Name "task-create-bulk: error_count is 0" `
        -Expected 0 `
        -Actual $result.error_count

} finally {
    foreach ($file in $createdFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-create-bulk"
if (-not $allPassed) { exit 1 }
