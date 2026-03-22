# Test session-update tool

. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\session-initialize\script.ps1"
. "$PSScriptRoot\..\session-get-state\script.ps1"

Write-Host "Testing session-update..." -ForegroundColor Cyan

# Setup: Initialize a session
Write-Host "`nSetup: Initialize session"
$initResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if (-not $initResult.success) {
    Write-Host "Setup failed: $($initResult.error)" -ForegroundColor Red
    exit 1
}

# Test 1: Update current task
Write-Host "`n1. Update current task ID"
$result = Invoke-SessionUpdate -Arguments @{ current_task_id = "task-123" }
if ($result.success -and $result.state.current_task_id -eq "task-123") {
    Write-Host "   PASS: Task ID updated" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Task ID not updated correctly" -ForegroundColor Red
}

# Test 2: Update status
Write-Host "`n2. Update status to paused"
$result = Invoke-SessionUpdate -Arguments @{ status = "paused" }
if ($result.success -and $result.state.status -eq "paused") {
    Write-Host "   PASS: Status updated" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Status not updated correctly" -ForegroundColor Red
}

# Test 3: Verify persistence
Write-Host "`n3. Verify updates persisted"
$getResult = Invoke-SessionGetState -Arguments @{}
if ($getResult.success -and $getResult.state.current_task_id -eq "task-123" -and $getResult.state.status -eq "paused") {
    Write-Host "   PASS: Updates persisted correctly" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Updates not persisted" -ForegroundColor Red
}

# Cleanup
Write-Host "`nCleanup"
$lockFile = Join-Path $PSScriptRoot "..\..\..\sessions\autonomous\session.lock"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
}

Write-Host "`nTests complete." -ForegroundColor Cyan
