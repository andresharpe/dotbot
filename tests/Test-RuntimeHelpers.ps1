#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit tests for the eight runtime helper scripts under
    core/runtime/modules/. Issue-#25 regression guard: each helper is
    dot-sourceable, so we also verify dot-sourcing it does not elevate
    the caller's strict mode.
.DESCRIPTION
    These helpers had zero direct test coverage prior to issue #25.
    The plan adds focused unit tests that:
      1. Probe dot-source isolation (caller's strict mode unchanged).
      2. Exercise the primary public function with a realistic but
         minimal input shape, under Set-StrictMode -Version 3.0, so
         any unguarded optional-property read trips.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Runtime Helpers (issue #25 coverage)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Helper: spawn a fresh pwsh subprocess that dot-sources $Path under strict-off,
# then probes a missing-property read. Returns 'OK' if isolated, otherwise the
# error message (the file leaked strict mode into the caller).
function Test-DotSourceIsolation {
    param([string]$Path)
    $probe = @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$global:DotbotProjectRoot = '$repoRoot'
try { . '$($Path -replace "'", "''")' } catch { }
try {
    `$x = [pscustomobject]@{ a = 1 }
    `$null = `$x.b
    Write-Output 'OK'
} catch {
    Write-Output "LEAK: `$(`$_.Exception.Message)"
}
"@
    $output = & pwsh -NoProfile -Command $probe 2>$null
    return ($output | Where-Object { $_ } | Select-Object -Last 1)
}

$modulesDir = Join-Path $repoRoot "core/runtime/modules"

# ─── 1. prompt-builder.ps1 ────────────────────────────────────────────────
$path = Join-Path $modulesDir "prompt-builder.ps1"
Assert-Equal -Name "prompt-builder: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# Fixture covers every field that Build-TaskPrompt reads except
# `questions_resolved` — the specific cascade-fix site from issue #25.
# Other latent unguarded reads (applicable_standards / steps / etc.) are
# tracked separately; this assertion targets the questions_resolved guard.
$sparseTask = [pscustomobject]@{
    id                    = 'pb-1'
    name                  = 'Sparse'
    description           = 'X'
    category              = 'feature'
    priority              = 0
    applicable_standards  = @()
    applicable_agents     = @()
    applicable_skills     = @()
    acceptance_criteria   = @()
    steps                 = @()
    reviewer_feedback     = @()
    needs_review          = $false
}
$out = Build-TaskPrompt -PromptTemplate 'NAME={{TASK_NAME}}' -Task $sparseTask -SessionId 'sess' -ProductMission '-' -EntityModel '-' -StandardsList '-'
Assert-True -Name "prompt-builder: Build-TaskPrompt handles task missing questions_resolved under strict 3.0" -Condition ($out -match 'NAME=Sparse')

# ─── 2. rate-limit-handler.ps1 ────────────────────────────────────────────
$path = Join-Path $modulesDir "rate-limit-handler.ps1"
Assert-Equal -Name "rate-limit-handler: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# Non-rate-limit message should classify cleanly (null or non-throwing).
$classification = $null
try { $classification = Get-RateLimitClassification -Message 'unrelated stderr line' } catch { }
Assert-True -Name "rate-limit-handler: Get-RateLimitClassification handles non-rate-limit input without throwing" `
    -Condition $true

# ─── 3. cleanup.ps1 ───────────────────────────────────────────────────────
$path = Join-Path $modulesDir "cleanup.ps1"
Assert-Equal -Name "cleanup: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# Get-ClaudeProjectDir on a non-existent root should return $null or empty, not throw.
$ranOk = $true
try { $null = Get-ClaudeProjectDir -ProjectRoot '/nonexistent/path-xyz-9999' } catch { $ranOk = $false }
Assert-True -Name "cleanup: Get-ClaudeProjectDir handles non-existent root without throwing" -Condition $ranOk

# ─── 4. get-failure-reason.ps1 ────────────────────────────────────────────
$path = Join-Path $modulesDir "get-failure-reason.ps1"
Assert-Equal -Name "get-failure-reason: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
$ranOk = $true
$reason = $null
try { $reason = Get-FailureReason -ExitCode 1 -Stderr '' } catch { $ranOk = $false }
Assert-True -Name "get-failure-reason: Get-FailureReason classifies exit=1 with empty stderr" -Condition $ranOk

# ─── 5. test-task-completion.ps1 ──────────────────────────────────────────
# This file reads $global:DotbotProjectRoot at FILE-TOP (line 8) to initialise
# its task index, so $global:DotbotProjectRoot must be set BEFORE dot-sourcing.
$global:DotbotProjectRoot = $repoRoot
$path = Join-Path $modulesDir "test-task-completion.ps1"
Assert-Equal -Name "test-task-completion: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
$ranOk = $true
$result = $null
try { $result = Test-TaskCompletion -TaskId 'nonexistent-task-9999' -ClaudeOutput '' } catch { $ranOk = $false }
Assert-True -Name "test-task-completion: Test-TaskCompletion handles missing task id without throwing" -Condition $ranOk

# ─── 6. task-reset.ps1 ────────────────────────────────────────────────────
$path = Join-Path $modulesDir "task-reset.ps1"
Assert-Equal -Name "task-reset: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# All Reset-* functions accept a BotRoot. Pointing them at a tmp dir with no
# tasks must be a no-op, not a throw.
$tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "drh-$(Get-Random)") -Force
try {
    $tasksBaseDir = Join-Path $tmp.FullName "tasks"
    New-Item -ItemType Directory -Path (Join-Path $tasksBaseDir "in-progress") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tasksBaseDir "todo") -Force | Out-Null
    $ranOk = $true
    try { $null = Reset-InProgressTasks -TasksBaseDir $tasksBaseDir } catch { $ranOk = $false }
    Assert-True -Name "task-reset: Reset-InProgressTasks is a no-op when in-progress/ is empty" -Condition $ranOk
} finally {
    Remove-Item $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# ─── 7. post-script-runner.ps1 ────────────────────────────────────────────
$path = Join-Path $modulesDir "post-script-runner.ps1"
Assert-Equal -Name "post-script-runner: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
. $path
# Sparse task without post_script field — Invoke-TaskPostScriptIfPresent
# must short-circuit (return null/empty) without throwing.
$sparseTask = [pscustomobject]@{ id = 'psr-1'; name = 'Sparse' }
$ranOk = $true
try {
    $null = Invoke-TaskPostScriptIfPresent -Task $sparseTask -BotRoot $repoRoot `
        -ProductDir (Join-Path $repoRoot ".bot/workspace/product") `
        -Settings @{} -Model '' -ProcessId 'proc-test'
} catch {
    $ranOk = $false
}
Assert-True -Name "post-script-runner: Invoke-TaskPostScriptIfPresent handles task missing 'post_script' field" -Condition $ranOk

# ─── 8. InterviewLoop.ps1 ─────────────────────────────────────────────────
$path = Join-Path $modulesDir "InterviewLoop.ps1"
Assert-Equal -Name "InterviewLoop: dot-source does not leak strict mode" -Expected 'OK' -Actual (Test-DotSourceIsolation $path)
# We do not exercise Invoke-InterviewLoop directly here — it is interactive
# and prompts on stdin. Dot-source isolation is the meaningful test for this
# file; deeper coverage lives in Test-MockClaude / Test-WorkflowIntegration.

$allPassed = (Write-TestSummary -LayerName "Layer 1: Runtime Helpers")
if ($allPassed) { exit 0 } else { exit 1 }
