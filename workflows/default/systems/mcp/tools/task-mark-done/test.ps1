# Test task-mark-done tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"
. "$PSScriptRoot\..\task-mark-in-progress\script.ps1"

Reset-TestResults

$cleanupFiles = @()

# Disable verification hooks (they require a git remote which test projects lack)
$verifyConfigPath = Join-Path $global:DotbotProjectRoot ".bot\hooks\verify\config.json"
$verifyBackup = $null
if (Test-Path $verifyConfigPath) {
    $verifyBackup = Get-Content $verifyConfigPath -Raw
    '{ "scripts": [] }' | Set-Content $verifyConfigPath -Encoding UTF8
}

try {
    $created = Invoke-TaskCreate -Arguments @{
        name = 'Done Test Task'
        description = 'Task for mark-done test'
        category = 'feature'
        priority = 25
    }
    $progress = Invoke-TaskMarkInProgress -Arguments @{ task_id = $created.task_id }

    Push-Location $global:DotbotProjectRoot
    & git add -A 2>&1 | Out-Null
    & git commit -m "test: add task for mark-done" --quiet 2>&1 | Out-Null
    Pop-Location

    $result = Invoke-TaskMarkDone -Arguments @{ task_id = $created.task_id }

    Assert-True -Name "task-mark-done: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-mark-done: new_status is done" `
        -Expected 'done' `
        -Actual $result.new_status

    $doneDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\done"
    $doneFile = Get-ChildItem -Path $doneDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $created.task_id
    }
    Assert-True -Name "task-mark-done: file moved to done/" `
        -Condition ($null -ne $doneFile) `
        -Message "File not found in done/"

    if ($doneFile) { $cleanupFiles += $doneFile.FullName }

    $duplicate = Invoke-TaskMarkDone -Arguments @{ task_id = $created.task_id }

    Assert-True -Name "task-mark-done: idempotent on duplicate" `
        -Condition ($duplicate.success -eq $true) `
        -Message "Second mark-done failed"

} finally {
    if ($verifyBackup) {
        Set-Content $verifyConfigPath $verifyBackup -Encoding UTF8
    }
    foreach ($file in $cleanupFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-mark-done"
if (-not $allPassed) { exit 1 }
