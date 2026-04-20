# Test task-mark-in-progress tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"

Reset-TestResults

$cleanupFiles = @()

try {
    $created = Invoke-TaskCreate -Arguments @{
        name = 'In-Progress Test Task'
        description = 'Task for mark-in-progress test'
        category = 'feature'
        priority = 30
    }

    $result = Invoke-TaskMarkInProgress -Arguments @{ task_id = $created.task_id }

    Assert-True -Name "task-mark-in-progress: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-mark-in-progress: new_status is in-progress" `
        -Expected 'in-progress' `
        -Actual $result.new_status

    $inProgressDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\in-progress"
    $ipFile = Get-ChildItem -Path $inProgressDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $created.task_id
    }
    Assert-True -Name "task-mark-in-progress: file moved to in-progress/" `
        -Condition ($null -ne $ipFile) `
        -Message "File not found in in-progress/"

    if ($ipFile) { $cleanupFiles += $ipFile.FullName }

} finally {
    foreach ($file in $cleanupFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-mark-in-progress"
if (-not $allPassed) { exit 1 }
