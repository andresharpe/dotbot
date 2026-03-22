# Test session-get-state tool

. "$PSScriptRoot\script.ps1"
. "$PSScriptRoot\..\session-initialize\script.ps1"

Write-Host "Testing session-get-state..." -ForegroundColor Cyan

# Setup: Initialize a session
Write-Host "`nSetup: Initialize session"
$initResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if (-not $initResult.success) {
    Write-Host "Setup failed: $($initResult.error)" -ForegroundColor Red
    exit 1
}

# Test 1: Get state
Write-Host "`n1. Get session state"
$result = Invoke-SessionGetState -Arguments @{}
if ($result.success) {
    Write-Host "   PASS: State retrieved" -ForegroundColor Green
    Write-Host "   Session ID: $($result.state.session_id)"
    Write-Host "   Status: $($result.state.status)"
} else {
    Write-Host "   FAIL: $($result.error)" -ForegroundColor Red
}

# Cleanup
Write-Host "`nCleanup"
$lockFile = Join-Path $PSScriptRoot "..\..\..\sessions\autonomous\session.lock"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
}

Write-Host "`nTests complete." -ForegroundColor Cyan
