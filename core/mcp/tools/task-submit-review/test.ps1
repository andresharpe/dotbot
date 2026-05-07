# Test task-submit-review tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"
. "$PSScriptRoot\..\task-mark-in-progress\script.ps1"
. "$PSScriptRoot\..\task-mark-needs-review\script.ps1"

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
    # ── Reject path ────────────────────────────────────────────────────────────
    $rejectTask = Invoke-TaskCreate -Arguments @{
        name         = 'SR Reject Test Task'
        description  = 'Task for submit-review reject path'
        category     = 'feature'
        priority     = 25
        effort       = 'XS'
        needs_review = $true
    }
    $cleanupFiles += $rejectTask.file_path
    Invoke-TaskMarkInProgress  -Arguments @{ task_id = $rejectTask.task_id } | Out-Null
    Invoke-TaskMarkNeedsReview -Arguments @{ task_id = $rejectTask.task_id } | Out-Null

    $rejectResult = Invoke-TaskSubmitReview -Arguments @{
        task_id       = $rejectTask.task_id
        approved      = $false
        comment       = 'Needs rework'
        what_was_wrong = 'Wrong approach chosen'
    }

    Assert-True -Name "task-submit-review reject: returns success" `
        -Condition ($rejectResult.success -eq $true) `
        -Message "Got: $($rejectResult.message)"

    Assert-Equal -Name "task-submit-review reject: new_status is todo" `
        -Expected 'todo' `
        -Actual $rejectResult.new_status

    Assert-Equal -Name "task-submit-review reject: approved is false" `
        -Expected $false `
        -Actual $rejectResult.approved

    $todoDir  = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\todo"
    $todoFile = Get-ChildItem -Path $todoDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $rejectTask.task_id } catch { $false }
    }
    Assert-True -Name "task-submit-review reject: file moved back to todo/" `
        -Condition ($null -ne $todoFile) `
        -Message "File not found in todo/"

    if ($todoFile) {
        $cleanupFiles += $todoFile.FullName
        $content = Get-Content $todoFile.FullName -Raw | ConvertFrom-Json
        Assert-Equal -Name "task-submit-review reject: review_status is rejected" `
            -Expected 'rejected' `
            -Actual $content.review_status
        Assert-True -Name "task-submit-review reject: feedback entry appended" `
            -Condition ($content.reviewer_feedback.Count -ge 1) `
            -Message "Expected at least one feedback entry"
    }

    # ── Approve path ───────────────────────────────────────────────────────────
    $approveTask = Invoke-TaskCreate -Arguments @{
        name         = 'SR Approve Test Task'
        description  = 'Task for submit-review approve path'
        category     = 'feature'
        priority     = 30
        effort       = 'XS'
        needs_review = $true
    }
    $cleanupFiles += $approveTask.file_path
    Invoke-TaskMarkInProgress  -Arguments @{ task_id = $approveTask.task_id } | Out-Null
    Invoke-TaskMarkNeedsReview -Arguments @{ task_id = $approveTask.task_id } | Out-Null

    $approveResult = Invoke-TaskSubmitReview -Arguments @{
        task_id  = $approveTask.task_id
        approved = $true
        comment  = 'Looks good'
    }

    Assert-True -Name "task-submit-review approve: returns success" `
        -Condition ($approveResult.success -eq $true) `
        -Message "Got: $($approveResult.error ?? $approveResult.message)"

    Assert-Equal -Name "task-submit-review approve: new_status is done" `
        -Expected 'done' `
        -Actual $approveResult.new_status

    $doneDir  = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\done"
    $doneFile = Get-ChildItem -Path $doneDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $approveTask.task_id } catch { $false }
    }
    Assert-True -Name "task-submit-review approve: file moved to done/" `
        -Condition ($null -ne $doneFile) `
        -Message "File not found in done/"

    if ($doneFile) {
        $cleanupFiles += $doneFile.FullName
        $content = Get-Content $doneFile.FullName -Raw | ConvertFrom-Json
        Assert-Equal -Name "task-submit-review approve: review_status is approved" `
            -Expected 'approved' `
            -Actual $content.review_status
    }

    # ── Error: task not in needs-review status ─────────────────────────────────
    $wrongState = $null
    try {
        $wrongState = Invoke-TaskSubmitReview -Arguments @{ task_id = 'nonexistent-task-id'; approved = $true }
    } catch {
        $wrongState = @{ error = $_.Exception.Message }
    }
    Assert-True -Name "task-submit-review: rejects non-existent task" `
        -Condition ($null -ne $wrongState.error -or $wrongState.success -eq $false) `
        -Message "Expected error for non-existent task"

} finally {
    if ($verifyBackup) {
        Set-Content $verifyConfigPath $verifyBackup -Encoding UTF8
    }
    foreach ($file in $cleanupFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-submit-review"
if (-not $allPassed) { exit 1 }
