# Test steering-heartbeat tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
$processesDir = Join-Path $controlDir "processes"
if (-not (Test-Path $processesDir)) {
    New-Item -ItemType Directory -Path $processesDir -Force | Out-Null
}

$testProcId = "proc-test01"
$procFile = Join-Path $processesDir "$testProcId.json"
$whisperFile = Join-Path $processesDir "$testProcId.whisper.jsonl"

$procBackup = $null
$whisperBackup = $null
if (Test-Path $procFile) { $procBackup = Get-Content $procFile -Raw }
if (Test-Path $whisperFile) { $whisperBackup = Get-Content $whisperFile -Raw }

try {
    if (Test-Path $procFile) { Remove-Item $procFile -Force }
    if (Test-Path $whisperFile) { Remove-Item $whisperFile -Force }

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

    $result = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test-session-123"
        process_id = $testProcId
        status = "Running unit tests"
        next_action = "Commit changes"
    }

    Assert-True -Name "steering-heartbeat: basic heartbeat succeeds" `
        -Condition ($result.success -eq $true) `
        -Message "Heartbeat failed"

    Assert-Equal -Name "steering-heartbeat: no whispers on clean state" `
        -Expected 0 `
        -Actual $result.whisper_count

    $procData = Get-Content $procFile -Raw | ConvertFrom-Json

    Assert-Equal -Name "steering-heartbeat: status persisted" `
        -Expected "Running unit tests" `
        -Actual $procData.heartbeat_status

    Assert-Equal -Name "steering-heartbeat: next_action persisted" `
        -Expected "Commit changes" `
        -Actual $procData.heartbeat_next_action

    # Add a whisper and verify delivery
    @{ instruction = "Focus on error handling"; priority = "normal"; timestamp = (Get-Date).ToUniversalTime().ToString("o") } |
        ConvertTo-Json -Compress |
        Add-Content -Path $whisperFile -Encoding utf8NoBOM

    $result2 = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test-session-123"
        process_id = $testProcId
        status = "Still running tests"
    }

    Assert-Equal -Name "steering-heartbeat: delivers 1 whisper" `
        -Expected 1 `
        -Actual $result2.whisper_count

    Assert-Equal -Name "steering-heartbeat: instruction matches" `
        -Expected "Focus on error handling" `
        -Actual $result2.whispers[0].instruction

    # Second call should not re-deliver
    $result3 = Invoke-SteeringHeartbeat -Arguments @{
        session_id = "test-session-123"
        process_id = $testProcId
        status = "Continuing work"
    }

    Assert-Equal -Name "steering-heartbeat: no duplicate delivery" `
        -Expected 0 `
        -Actual $result3.whisper_count

} finally {
    if (Test-Path $procFile) { Remove-Item $procFile -Force }
    if (Test-Path $whisperFile) { Remove-Item $whisperFile -Force }
    if ($procBackup) { Set-Content -Path $procFile -Value $procBackup -NoNewline }
    if ($whisperBackup) { Set-Content -Path $whisperFile -Value $whisperBackup -NoNewline }
}

$allPassed = Write-TestSummary -LayerName "steering-heartbeat"
if (-not $allPassed) { exit 1 }
