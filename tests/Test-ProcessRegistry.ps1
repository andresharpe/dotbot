#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Unit tests for ProcessRegistry.psm1 module.
.DESCRIPTION
    Tests process lifecycle functions: ID generation, file I/O, locking,
    activity logging, diagnostics, preflight checks, and task selection helpers.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: ProcessRegistry Module Tests" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally - run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: ProcessRegistry"
    exit 1
}

$modulePath = Join-Path $dotbotDir "core/runtime/modules/ProcessRegistry.psm1"
$dotBotLogPath = Join-Path $dotbotDir "core/runtime/modules/DotBotLog.psm1"

# ===================================================================
# MODULE LOADING
# ===================================================================

Write-Host "  MODULE LOADING" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

try {
    # Import DotBotLog first (provides Write-Diag and Write-BotLog used by ProcessRegistry)
    if (Test-Path $dotBotLogPath) {
        Import-Module $dotBotLogPath -Force -DisableNameChecking
    }
    Import-Module $modulePath -Force
    Write-TestResult -Name "ProcessRegistry.psm1 imports without error" -Status Pass
} catch {
    Write-TestResult -Name "ProcessRegistry.psm1 imports without error" -Status Fail -Message $_.Exception.Message
    Write-TestSummary -LayerName "Layer 2: ProcessRegistry"
    exit 1
}

# ===================================================================
# SETUP: Temporary directories for isolated testing
# ===================================================================

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-registry-$(Get-Random)"
$testControlDir = Join-Path $testRoot "control"
$testProcessesDir = Join-Path $testControlDir "processes"
New-Item -Path $testProcessesDir -ItemType Directory -Force | Out-Null

$testDiagLog = Join-Path $testControlDir "diag-test.log"
$testLogsDir = Join-Path $testControlDir "logs"
New-Item -Path $testLogsDir -ItemType Directory -Force | Out-Null

# Initialize DotBotLog for Write-Diag support
if (Get-Command Initialize-DotBotLog -ErrorAction SilentlyContinue) {
    Initialize-DotBotLog -LogDir $testLogsDir -ControlDir $testControlDir -ProjectRoot $testRoot -ConsoleEnabled $false
}

# Initialize with test directories
Initialize-ProcessRegistry `
    -ProcessesDir $testProcessesDir `
    -ControlDir $testControlDir `
    -DiagLogPath $testDiagLog `
    -Settings @{ operations = @{ file_retry_count = 2; file_retry_base_ms = 10 } } `
    -ProviderConfig @{ executable = "git"; display_name = "Git" } `
    -BotRoot $testRoot

# ===================================================================
# New-ProcessId
# ===================================================================

Write-Host "  NEW-PROCESSID" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$pid1 = New-ProcessId
$pid2 = New-ProcessId
Assert-True -Name "New-ProcessId returns proc- prefix" `
    -Condition ($pid1 -match '^proc-[a-f0-9]{6}$') `
    -Message "Got: $pid1"

Assert-True -Name "New-ProcessId returns unique values" `
    -Condition ($pid1 -ne $pid2) `
    -Message "Got same value twice: $pid1"

# ===================================================================
# Write-ProcessFile
# ===================================================================

Write-Host "  WRITE-PROCESSFILE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$testProcId = "proc-test01"
$testData = @{
    id     = $testProcId
    type   = "test"
    status = "running"
}
Write-ProcessFile -Id $testProcId -Data $testData
$writtenFile = Join-Path $testProcessesDir "$testProcId.json"
Assert-True -Name "Write-ProcessFile creates JSON file" `
    -Condition (Test-Path $writtenFile) `
    -Message "File not found at $writtenFile"

$readBack = Get-Content $writtenFile -Raw | ConvertFrom-Json
Assert-True -Name "Write-ProcessFile JSON content is correct" `
    -Condition ($readBack.id -eq $testProcId -and $readBack.status -eq "running") `
    -Message "Content mismatch: id=$($readBack.id), status=$($readBack.status)"

# ===================================================================
# Write-ProcessActivity
# ===================================================================

Write-Host "  WRITE-PROCESSACTIVITY" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Write-ProcessActivity -Id $testProcId -ActivityType "text" -Message "Test activity entry"
$activityFile = Join-Path $testProcessesDir "$testProcId.activity.jsonl"
Assert-True -Name "Write-ProcessActivity creates JSONL file" `
    -Condition (Test-Path $activityFile) `
    -Message "Activity file not found"

$activityLine = (Get-Content $activityFile | Select-Object -First 1) | ConvertFrom-Json
Assert-True -Name "Write-ProcessActivity JSONL has correct type" `
    -Condition ($activityLine.type -eq "text") `
    -Message "Got type: $($activityLine.type)"

Assert-True -Name "Write-ProcessActivity JSONL has correct message" `
    -Condition ($activityLine.message -eq "Test activity entry") `
    -Message "Got message: $($activityLine.message)"

# ===================================================================
# Write-Diag
# ===================================================================

Write-Host "  WRITE-DIAG" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Write-Diag "Test diagnostic message"
$dateStamp = Get-Date -Format 'yyyy-MM-dd'
$diagLogFile = Join-Path $testLogsDir "dotbot-$dateStamp.jsonl"
Assert-True -Name "Write-Diag creates structured log file" `
    -Condition (Test-Path $diagLogFile) `
    -Message "Structured log not found at $diagLogFile"

$diagLines = @(Get-Content $diagLogFile)
$diagMatch = $diagLines | Where-Object { $_ -match "Test diagnostic message" }
Assert-True -Name "Write-Diag writes message to structured log" `
    -Condition ($null -ne $diagMatch) `
    -Message "Diagnostic message not found in structured log"

# ===================================================================
# Process Locking
# ===================================================================

Write-Host "  PROCESS LOCKING" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

# Start clean
Remove-ProcessLock -LockType "test-lock"

$acquired = Request-ProcessLock -LockType "test-lock"
Assert-True -Name "Request-ProcessLock succeeds on fresh lock" `
    -Condition ($acquired -eq $true) `
    -Message "Failed to acquire lock"

$lockFile = Join-Path $testControlDir "launch-test-lock.lock"
Assert-True -Name "Request-ProcessLock creates lock file" `
    -Condition (Test-Path $lockFile) `
    -Message "Lock file not found"

$lockContent = (Get-Content $lockFile -Raw).Trim()
Assert-True -Name "Request-ProcessLock writes current PID" `
    -Condition ($lockContent -eq $PID.ToString()) `
    -Message "Expected PID $PID, got: $lockContent"

$isLocked = Test-ProcessLock -LockType "test-lock"
Assert-True -Name "Test-ProcessLock returns true for active lock" `
    -Condition ($isLocked -eq $true) `
    -Message "Expected true, got false"

Remove-ProcessLock -LockType "test-lock"
Assert-True -Name "Remove-ProcessLock deletes lock file" `
    -Condition (-not (Test-Path $lockFile)) `
    -Message "Lock file still exists"

$isLockedAfter = Test-ProcessLock -LockType "test-lock"
Assert-True -Name "Test-ProcessLock returns false after removal" `
    -Condition ($isLockedAfter -eq $false) `
    -Message "Expected false, got true"

# Test stale lock cleanup (write a dead PID)
Set-ProcessLock -LockType "stale-test"
$staleLockFile = Join-Path $testControlDir "launch-stale-test.lock"
# Write a PID that doesn't exist (use a high number unlikely to be a real process)
"99999" | Set-Content $staleLockFile -NoNewline -Encoding utf8NoBOM
$acquiredStale = Request-ProcessLock -LockType "stale-test"
Assert-True -Name "Request-ProcessLock cleans stale lock (dead PID)" `
    -Condition ($acquiredStale -eq $true) `
    -Message "Failed to acquire lock after stale cleanup"
Remove-ProcessLock -LockType "stale-test"

# ===================================================================
# Test-ProcessStopSignal
# ===================================================================

Write-Host "  TEST-PROCESSSTOPSIGNAL" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$noStop = Test-ProcessStopSignal -Id "proc-nosignal"
Assert-True -Name "Test-ProcessStopSignal returns false when no stop file" `
    -Condition ($noStop -eq $false) `
    -Message "Expected false"

# Create a stop file
"" | Set-Content (Join-Path $testProcessesDir "proc-stopped.stop") -NoNewline
$hasStop = Test-ProcessStopSignal -Id "proc-stopped"
Assert-True -Name "Test-ProcessStopSignal returns true when stop file exists" `
    -Condition ($hasStop -eq $true) `
    -Message "Expected true"

# ===================================================================
# Add-YamlFrontMatter
# ===================================================================

Write-Host "  ADD-YAMLFRONTMATTER" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$testMdFile = Join-Path $testRoot "test-frontmatter.md"
"# Hello World" | Set-Content $testMdFile -Encoding utf8NoBOM
Add-YamlFrontMatter -FilePath $testMdFile -Metadata @{ author = "test"; version = "1.0" }
$fmContent = Get-Content $testMdFile -Raw
Assert-True -Name "Add-YamlFrontMatter prepends YAML block" `
    -Condition ($fmContent -match '^---' -and $fmContent -match 'author: "test"' -and $fmContent -match '# Hello World') `
    -Message "Front matter not correctly prepended"

# ===================================================================
# CLEANUP
# ===================================================================

try {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

Write-Host ""

# ===================================================================
# SUMMARY
# ===================================================================

$allPassed = Write-TestSummary -LayerName "Layer 2: ProcessRegistry"

if (-not $allPassed) {
    exit 1
}
