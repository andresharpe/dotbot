# Test task-get-stats tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$result = Invoke-TaskGetStats -Arguments @{}

Assert-True -Name "task-get-stats: returns success" `
    -Condition ($result.success -eq $true) `
    -Message "Expected success"

Assert-True -Name "task-get-stats: has total_tasks" `
    -Condition ($null -ne $result.total_tasks) `
    -Message "total_tasks is null"

Assert-True -Name "task-get-stats: has summary" `
    -Condition ($null -ne $result.summary) `
    -Message "summary is null"

$allPassed = Write-TestSummary -LayerName "task-get-stats"
if (-not $allPassed) { exit 1 }
