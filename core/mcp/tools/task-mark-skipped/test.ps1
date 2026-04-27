# Test task-mark-skipped tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"
. "$PSScriptRoot\..\task-mark-in-progress\script.ps1"

Reset-TestResults

$cleanupFiles = @()

try {
    $created = Invoke-TaskCreate -Arguments @{
        name = 'Skip Test Task'
        description = 'Task for mark-skipped test'
        category = 'feature'
        priority = 50
    }
    $progress = Invoke-TaskMarkInProgress -Arguments @{ task_id = $created.task_id }

    $result = Invoke-TaskMarkSkipped -Arguments @{
        task_id = $created.task_id
        skip_reason = 'non-recoverable'
    }

    Assert-True -Name "task-mark-skipped: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-mark-skipped: new_status is skipped" `
        -Expected 'skipped' `
        -Actual $result.new_status

    Assert-Equal -Name "task-mark-skipped: skip_count is 1" `
        -Expected 1 `
        -Actual $result.skip_count

    # Verify file in skipped/
    $skippedDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\skipped"
    $skippedFile = Get-ChildItem -Path $skippedDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $created.task_id
    }
    Assert-True -Name "task-mark-skipped: file moved to skipped/" `
        -Condition ($null -ne $skippedFile) `
        -Message "File not found in skipped/"

    if ($skippedFile) { $cleanupFiles += $skippedFile.FullName }

    # Verify skip_history content
    if ($skippedFile) {
        $content = Get-Content $skippedFile.FullName -Raw | ConvertFrom-Json

        Assert-True -Name "task-mark-skipped: skip_history has 1 entry" `
            -Condition ($content.skip_history.Count -eq 1) `
            -Message "Expected 1 entry, got $($content.skip_history.Count)"

        Assert-Equal -Name "task-mark-skipped: skip_history reason matches" `
            -Expected 'non-recoverable' `
            -Actual $content.skip_history[0].reason

        # Skip again to verify append
        $result2 = Invoke-TaskMarkSkipped -Arguments @{
            task_id = $created.task_id
            skip_reason = 'max-retries'
        }

        Assert-Equal -Name "task-mark-skipped: second skip_count is 2" `
            -Expected 2 `
            -Actual $result2.skip_count
    }

} finally {
    foreach ($file in $cleanupFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-mark-skipped"
if (-not $allPassed) { exit 1 }
