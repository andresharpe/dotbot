# Test session-increment-completed tool

. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\session-initialize\script.ps1"

Write-Host "Testing session-increment-completed..." -ForegroundColor Cyan

# Setup: Initialize a session
Write-Host "`nSetup: Initialize session"
$initResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if (-not $initResult.success) {
    Write-Host "Setup failed: $($initResult.error)" -ForegroundColor Red
    exit 1
}

# Test 1: Increment once
Write-Host "`n1. Increment completed tasks"
$result = Invoke-SessionIncrementCompleted -Arguments @{}
if ($result.success -and $result.tasks_completed -eq 1) {
    Write-Host "   PASS: Incremented to 1" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Expected 1, got $($result.tasks_completed)" -ForegroundColor Red
}

# Test 2: Increment again
Write-Host "`n2. Increment again"
$result = Invoke-SessionIncrementCompleted -Arguments @{}
if ($result.success -and $result.tasks_completed -eq 2) {
    Write-Host "   PASS: Incremented to 2" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Expected 2, got $($result.tasks_completed)" -ForegroundColor Red
}

# Test 3: Verify consecutive_failures reset
Write-Host "`n3. Verify consecutive_failures is 0"
if ($result.consecutive_failures -eq 0) {
    Write-Host "   PASS: consecutive_failures reset to 0" -ForegroundColor Green
} else {
    Write-Host "   FAIL: consecutive_failures should be 0" -ForegroundColor Red
}

# Cleanup
Write-Host "`nCleanup"
$lockFile = Join-Path $PSScriptRoot "..\..\..\sessions\autonomous\session.lock"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
}

Write-Host "`nTests complete." -ForegroundColor Cyan
