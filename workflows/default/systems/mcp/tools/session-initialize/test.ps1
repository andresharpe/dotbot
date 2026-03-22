# Test session-initialize tool

. "$PSScriptRoot\script.ps1"

Write-Host "Testing session-initialize..." -ForegroundColor Cyan

# Test 1: Initialize autonomous session
Write-Host "`n1. Initialize autonomous session"
$result = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if ($result.success) {
    Write-Host "   PASS: Session initialized" -ForegroundColor Green
    Write-Host "   Session ID: $($result.session.session_id)"
} else {
    Write-Host "   FAIL: $($result.error)" -ForegroundColor Red
}

# Test 2: Try to initialize again (should fail due to lock)
Write-Host "`n2. Try to initialize again (should fail)"
$result = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if (-not $result.success -and $result.error -like "*already locked*") {
    Write-Host "   PASS: Lock detected correctly" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should have detected lock" -ForegroundColor Red
}

# Test 3: Clean up
Write-Host "`n3. Cleanup"
$lockFile = Join-Path $PSScriptRoot "..\..\..\sessions\autonomous\session.lock"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
    Write-Host "   PASS: Lock file removed" -ForegroundColor Green
}

Write-Host "`nTests complete." -ForegroundColor Cyan
