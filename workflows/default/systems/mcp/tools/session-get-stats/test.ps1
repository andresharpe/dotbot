# Test session-get-stats tool

. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\session-initialize\script.ps1"
. "$PSScriptRoot\..\session-increment-completed\script.ps1"

Write-Host "Testing session-get-stats..." -ForegroundColor Cyan

# Setup: Initialize a session
Write-Host "`nSetup: Initialize session"
$initResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if (-not $initResult.success) {
    Write-Host "Setup failed: $($initResult.error)" -ForegroundColor Red
    exit 1
}

# Add some completed tasks
Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null

# Test 1: Get stats
Write-Host "`n1. Get session statistics"
$result = Invoke-SessionGetStats -Arguments @{}
if ($result.success) {
    Write-Host "   PASS: Stats retrieved" -ForegroundColor Green
    Write-Host "   Session ID: $($result.session_id)"
    Write-Host "   Tasks completed: $($result.tasks_completed)"
    Write-Host "   Runtime: $($result.runtime_hours)h"
    Write-Host "   Completion rate: $($result.completion_rate)%"
    Write-Host "   Summary: $($result.summary)"
} else {
    Write-Host "   FAIL: $($result.error)" -ForegroundColor Red
}

# Test 2: Verify calculations
Write-Host "`n2. Verify calculation accuracy"
if ($result.tasks_completed -eq 2 -and $result.total_processed -eq 2 -and $result.completion_rate -eq 100) {
    Write-Host "   PASS: Calculations correct" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Calculations incorrect" -ForegroundColor Red
    Write-Host "   Expected: 2 tasks, 2 total, 100% rate"
    Write-Host "   Got: $($result.tasks_completed) tasks, $($result.total_processed) total, $($result.completion_rate)% rate"
}

# Cleanup
Write-Host "`nCleanup"
$lockFile = Join-Path $PSScriptRoot "..\..\..\sessions\autonomous\session.lock"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
}

Write-Host "`nTests complete." -ForegroundColor Cyan
