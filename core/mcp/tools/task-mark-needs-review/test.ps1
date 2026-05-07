# Test task-mark-needs-review tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\task-create\script.ps1"

Reset-TestResults

$cleanupFiles = @()

try {
    # ── Happy path: needs_review=true task transitions to needs-review ──────────
    $created = Invoke-TaskCreate -Arguments @{
        name        = 'NR Mark Test Task'
        description = 'Task for mark-needs-review test'
        category    = 'feature'
        priority    = 20
        effort      = 'XS'
        needs_review = $true
    }
    $cleanupFiles += $created.file_path

    # Move directly to in-progress via Set-TaskState (bypasses FrameworkIntegrity
    # gate which blocks Invoke-TaskMarkInProgress in test environments due to
    # manifest mismatch from instance_id regeneration in the test project setup).
    Set-TaskState -TaskId $created.task_id -FromStates @('todo') -ToState 'in-progress' -Updates @{} | Out-Null

    $result = Invoke-TaskMarkNeedsReview -Arguments @{ task_id = $created.task_id }

    Assert-True -Name "task-mark-needs-review: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-mark-needs-review: new_status is needs-review" `
        -Expected 'needs-review' `
        -Actual $result.new_status

    $nrDir  = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\needs-review"
    $nrFile = Get-ChildItem -Path $nrDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $created.task_id } catch { $false }
    }
    Assert-True -Name "task-mark-needs-review: file moved to needs-review/" `
        -Condition ($null -ne $nrFile) `
        -Message "File not found in needs-review/"

    if ($nrFile) {
        $cleanupFiles += $nrFile.FullName
        $content = Get-Content $nrFile.FullName -Raw | ConvertFrom-Json
        Assert-Equal -Name "task-mark-needs-review: review_status is pending" `
            -Expected 'pending' `
            -Actual $content.review_status
    }

    # ── Idempotency: calling again while already in needs-review returns success ─
    $idempotentResult = Invoke-TaskMarkNeedsReview -Arguments @{ task_id = $created.task_id }
    Assert-True -Name "task-mark-needs-review: idempotent on already-in-needs-review" `
        -Condition ($idempotentResult.success -eq $true) `
        -Message "Got: $($idempotentResult.message)"

    # ── Error: task without needs_review flag is rejected ──────────────────────
    $plain = Invoke-TaskCreate -Arguments @{
        name        = 'NR Mark Plain Task'
        description = 'Task without needs_review'
        category    = 'feature'
        priority    = 10
        effort      = 'XS'
    }
    $cleanupFiles += $plain.file_path
    Set-TaskState -TaskId $plain.task_id -FromStates @('todo') -ToState 'in-progress' -Updates @{} | Out-Null

    $inProgressDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\in-progress"
    $plainFile = Get-ChildItem -Path $inProgressDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $plain.task_id } catch { $false }
    }
    if ($plainFile) { $cleanupFiles += $plainFile.FullName }

    $badResult = $null
    try {
        $badResult = Invoke-TaskMarkNeedsReview -Arguments @{ task_id = $plain.task_id }
    } catch {
        $badResult = @{ error = $_.Exception.Message }
    }
    Assert-True -Name "task-mark-needs-review: rejects task without needs_review flag" `
        -Condition ($null -ne $badResult.error -or $badResult.success -eq $false) `
        -Message "Expected error for task without needs_review=true"

    # ── Error: non-existent task ID ────────────────────────────────────────────
    $notFound = $null
    try {
        $notFound = Invoke-TaskMarkNeedsReview -Arguments @{ task_id = 'nonexistent-task-id' }
    } catch {
        $notFound = @{ error = $_.Exception.Message }
    }
    Assert-True -Name "task-mark-needs-review: rejects non-existent task" `
        -Condition ($null -ne $notFound.error -or $notFound.success -eq $false) `
        -Message "Expected error for non-existent task ID"

} finally {
    foreach ($file in $cleanupFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "task-mark-needs-review"
if (-not $allPassed) { exit 1 }
