# Test steering-heartbeat tool

. "$PSScriptRoot\script.ps1"

Write-Host "Testing steering-heartbeat..." -ForegroundColor Cyan

$controlDir = Join-Path $PSScriptRoot "..\..\..\..\..\.control"
$controlDir = [System.IO.Path]::GetFullPath($controlDir)
$processesDir = Join-Path $controlDir "processes"

if (-not (Test-Path $processesDir)) {
    New-Item -ItemType Directory -Path $processesDir -Force | Out-Null
}

$testProcId = "proc-test01"
$procFile = Join-Path $processesDir "$testProcId.json"
$whisperFile = Join-Path $processesDir "$testProcId.whisper.jsonl"

# Backup existing files
$procBackup = $null
$whisperBackup = $null
if (Test-Path $procFile) { $procBackup = Get-Content $procFile -Raw }
if (Test-Path $whisperFile) { $whisperBackup = Get-Content $whisperFile -Raw }

try {
    # Clean slate
    if (Test-Path $procFile) { Remove-Item $procFile -Force }
    if (Test-Path $whisperFile) { Remove-Item $whisperFile -Force }

    # Create a test process registry entry
    @{
        id = $testProcId
        type = "execution"
        status = "running"
        pid = $PID
        started_at = (Get-Date).ToUniversalTime().ToString("o")
        last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
        last_whisper_index = 0
        heartbeat_status = $null
        heartbeat_next_action = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $procFile -Encoding utf8NoBOM

    # Test 1: Basic heartbeat with no whispers
    Write-Host "`n1. Basic heartbeat (no whispers)"
    $result = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test-session-123"
        process_id = $testProcId
        status = "Running unit tests"
        next_action = "Commit changes"
    }
    if ($result.success -and $result.whisper_count -eq 0) {
        Write-Host "   PASS: Heartbeat successful, no whispers" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: $($result | ConvertTo-Json -Compress)" -ForegroundColor Red
    }

    # Test 2: Verify process file was updated
    Write-Host "`n2. Verify process file updated"
    $procData = Get-Content $procFile -Raw | ConvertFrom-Json
    if ($procData.heartbeat_status -eq "Running unit tests" -and $procData.heartbeat_next_action -eq "Commit changes") {
        Write-Host "   PASS: Process file contains correct heartbeat data" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Process file has wrong content" -ForegroundColor Red
    }

    # Test 3: Add a whisper and verify it's returned
    Write-Host "`n3. Test whisper delivery"
    $whisper = @{
        instruction = "Focus on error handling"
        priority = "normal"
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress
    Add-Content -Path $whisperFile -Value $whisper -Encoding utf8NoBOM

    $result = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test-session-123"
        process_id = $testProcId
        status = "Still running tests"
    }
    if ($result.success -and $result.whisper_count -eq 1 -and $result.whispers[0].instruction -eq "Focus on error handling") {
        Write-Host "   PASS: Whisper delivered correctly" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Whisper not delivered - $($result | ConvertTo-Json -Compress)" -ForegroundColor Red
    }

    # Test 4: Verify whisper is NOT returned again (index tracking)
    Write-Host "`n4. Test whisper index tracking (no duplicate delivery)"
    $result = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test-session-123"
        process_id = $testProcId
        status = "Continuing work"
    }
    if ($result.success -and $result.whisper_count -eq 0) {
        Write-Host "   PASS: No duplicate whisper delivery" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Got duplicate whispers - count: $($result.whisper_count)" -ForegroundColor Red
    }

    # Test 5: Required parameters validation
    Write-Host "`n5. Test required parameter validation"
    $result = Invoke-SteeringHeartbeat -Arguments @{
        status = "Missing session_id and process_id"
    }
    if (-not $result.success -and $result.error -match "session_id") {
        Write-Host "   PASS: session_id validation works" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: session_id validation broken" -ForegroundColor Red
    }

    $result = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test"
        status = "Missing process_id"
    }
    if (-not $result.success -and $result.error -match "process_id") {
        Write-Host "   PASS: process_id validation works" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: process_id validation broken" -ForegroundColor Red
    }

    $result = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test"
        process_id = $testProcId
    }
    if (-not $result.success -and $result.error -match "status") {
        Write-Host "   PASS: status validation works" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: status validation broken" -ForegroundColor Red
    }

} finally {
    # Cleanup: restore backups
    if (Test-Path $procFile) { Remove-Item $procFile -Force }
    if (Test-Path $whisperFile) { Remove-Item $whisperFile -Force }
    if ($procBackup) { Set-Content -Path $procFile -Value $procBackup -NoNewline }
    if ($whisperBackup) { Set-Content -Path $whisperFile -Value $whisperBackup -NoNewline }
}

Write-Host "`nTests complete." -ForegroundColor Cyan
