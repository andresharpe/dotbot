#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Unit tests for the Dotbot.Process module.
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
Write-Host "  Layer 2: Dotbot.Process Module Tests" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally - set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 2: Dotbot.Process"
    exit 1
}

$modulePath = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1"
$dotBotLogPath = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Logging/Dotbot.Logging.psd1"

# ===================================================================
# MODULE LOADING
# ===================================================================

Write-Host "  MODULE LOADING" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

try {
    # Import Dotbot.Logging first (provides Write-Diag and Write-BotLog used by Dotbot.Process)
    if (Test-Path $dotBotLogPath) {
        Import-Module $dotBotLogPath -Force -DisableNameChecking
    }
    Import-Module $modulePath -Force
    Write-TestResult -Name "Dotbot.Process module imports without error" -Status Pass
} catch {
    Write-TestResult -Name "Dotbot.Process module imports without error" -Status Fail -Message $_.Exception.Message
    Write-TestSummary -LayerName "Layer 2: Dotbot.Process"
    exit 1
}

# ===================================================================
# SETUP: Temporary directories for isolated testing
# ===================================================================

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-registry-$(Get-Random)"
$testControlDir = Join-Path $testRoot ".control"
$testProcessesDir = Join-Path $testControlDir "processes"
New-Item -Path $testProcessesDir -ItemType Directory -Force | Out-Null

$testLogsDir = Join-Path $testControlDir "logs"
New-Item -Path $testLogsDir -ItemType Directory -Force | Out-Null

# Initialize Dotbot.Logging for Write-Diag support
if (Get-Command Initialize-DotbotLog -ErrorAction SilentlyContinue) {
    Initialize-DotbotLog -LogDir $testLogsDir -ControlDir $testControlDir -ProjectRoot $testRoot -ConsoleEnabled $false
}

# Dotbot.Process is stateless — pass -BotRoot $testRoot per call.
# $testRoot is treated as a synthetic .bot/, so Get-ProcessesDir resolves
# to $testRoot/.control/processes which matches what we created above.
$PSDefaultParameterValues['*:BotRoot'] = $testRoot

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
# Add-JsonFrontMatter
# ===================================================================

Write-Host "  ADD-JSONFRONTMATTER" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$testMdFile = Join-Path $testRoot "test-frontmatter.md"
"# Hello World" | Set-Content $testMdFile -Encoding utf8NoBOM
Add-JsonFrontMatter -FilePath $testMdFile -Metadata @{ author = "test"; version = "1.0" }
$fmContent = Get-Content $testMdFile -Raw
Assert-True -Name "Add-JsonFrontMatter prepends JSON block" `
    -Condition ($fmContent -match '^---' -and $fmContent -match '"author":\s*"test"' -and $fmContent -match '# Hello World') `
    -Message "Front matter not correctly prepended"

# ===================================================================
# Register-DotbotKillOnCloseJob (#645)
# ===================================================================

Write-Host "  REGISTER-DOTBOTKILLONCLOSEJOB" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Assert-True -Name "Register-DotbotKillOnCloseJob is exported" `
    -Condition ([bool](Get-Command Register-DotbotKillOnCloseJob -Module Dotbot.Process -ErrorAction SilentlyContinue)) `
    -Message "Register-DotbotKillOnCloseJob should be exported from Dotbot.Process"

if (-not $IsWindows) {
    # Job Objects are Windows-only; the helper is a documented no-op elsewhere.
    Assert-Equal -Name "Register-DotbotKillOnCloseJob returns false on non-Windows" `
        -Expected $false -Actual (Register-DotbotKillOnCloseJob)
} else {
    # End-to-end: a worker binds itself to a kill-on-close job, spawns a
    # child subtree (mid -> leaf, modelling claude.exe -> MCP server), then is
    # force-killed WITHOUT running any cleanup. The kernel must reap the subtree.
    $jobTestDir = Join-Path $testRoot "killjob"
    New-Item -Path $jobTestDir -ItemType Directory -Force | Out-Null

    $leafScript = Join-Path $jobTestDir "leaf.ps1"
    $midScript = Join-Path $jobTestDir "mid.ps1"
    $workerScript = Join-Path $jobTestDir "worker.ps1"
    $pidFile = Join-Path $jobTestDir "pids.txt"
    $bindResultFile = Join-Path $jobTestDir "bind.txt"

    Set-Content -LiteralPath $leafScript -Encoding utf8NoBOM -Value 'Start-Sleep -Seconds 300'

    Set-Content -LiteralPath $midScript -Encoding utf8NoBOM -Value @'
param([string]$LeafScript, [string]$PidFile)
$leaf = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $LeafScript -WindowStyle Hidden -PassThru
Set-Content -LiteralPath $PidFile -Value @("$PID", "$($leaf.Id)")
Start-Sleep -Seconds 300
'@

    Set-Content -LiteralPath $workerScript -Encoding utf8NoBOM -Value @'
param([string]$LoggingPsd1, [string]$ProcessPsd1, [string]$MidScript, [string]$LeafScript, [string]$PidFile, [string]$BindResultFile)
Import-Module $LoggingPsd1 -Force -DisableNameChecking
Import-Module $ProcessPsd1 -Force
$bound = Register-DotbotKillOnCloseJob
Set-Content -LiteralPath $BindResultFile -Value ([string]$bound)
Start-Process pwsh -ArgumentList '-NoProfile', '-File', $MidScript, '-LeafScript', $LeafScript, '-PidFile', $PidFile -WindowStyle Hidden
Start-Sleep -Seconds 300
'@

    $worker = $null
    try {
        $worker = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-File', $workerScript,
            '-LoggingPsd1', $dotBotLogPath,
            '-ProcessPsd1', $modulePath,
            '-MidScript', $midScript,
            '-LeafScript', $leafScript,
            '-PidFile', $pidFile,
            '-BindResultFile', $bindResultFile
        )

        # Wait until the subtree records its PIDs (module compile + 3x pwsh spawn).
        $descendants = $null
        $readyDeadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $readyDeadline) {
            if (Test-Path $pidFile) {
                $lines = @(Get-Content $pidFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d+$' })
                if ($lines.Count -ge 2) { $descendants = $lines | ForEach-Object { [int]$_ }; break }
            }
            Start-Sleep -Milliseconds 250
        }

        $bindResult = if (Test-Path $bindResultFile) { (Get-Content $bindResultFile -Raw).Trim() } else { "" }
        Assert-Equal -Name "Register-DotbotKillOnCloseJob binds the worker (returns true)" `
            -Expected "True" -Actual $bindResult

        Assert-True -Name "Worker subtree started (descendant PIDs recorded)" `
            -Condition ($null -ne $descendants) `
            -Message "Worker never recorded its descendant PIDs within the timeout"

        if ($descendants) {
            $midPid, $leafPid = $descendants[0], $descendants[1]

            # Abrupt kill -- the worker's in-process cleanup never runs.
            Stop-Process -Id $worker.Id -Force

            # Poll for the subtree to be reaped by the kernel.
            $reapDeadline = (Get-Date).AddSeconds(20)
            do {
                $midAlive = [bool](Get-Process -Id $midPid -ErrorAction SilentlyContinue)
                $leafAlive = [bool](Get-Process -Id $leafPid -ErrorAction SilentlyContinue)
                if (-not $midAlive -and -not $leafAlive) { break }
                Start-Sleep -Milliseconds 250
            } while ((Get-Date) -lt $reapDeadline)

            Assert-True -Name "Force-killing worker reaps child (claude.exe stand-in)" `
                -Condition (-not $midAlive) `
                -Message "Child PID $midPid survived as an orphan after worker was force-killed"
            Assert-True -Name "Force-killing worker reaps grandchild (MCP stand-in)" `
                -Condition (-not $leafAlive) `
                -Message "Grandchild PID $leafPid survived as an orphan after worker was force-killed"

            # Belt-and-braces cleanup in case an assertion above failed.
            # Stop-Process -ErrorAction SilentlyContinue does not throw on an
            # already-dead PID, so no try/catch is needed.
            foreach ($p in @($midPid, $leafPid)) {
                Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        if ($worker) { Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue }
    }
}

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

$allPassed = Write-TestSummary -LayerName "Layer 2: Dotbot.Process"

if (-not $allPassed) {
    exit 1
}
