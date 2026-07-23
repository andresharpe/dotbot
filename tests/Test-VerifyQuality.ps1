#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Quality gate verify hook tests (#656).
.DESCRIPTION
    Tests the 05-verify-quality.ps1 verify hook: disabled/no-op by default,
    skips when enabled but unconfigured, and runs+reports configured
    test/lint commands, failing the gate when either command exits non-zero.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot
$scriptPath = Join-Path $repoRoot "src/hooks/verify/05-verify-quality.ps1"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Quality Gate Verify Hook Tests (#656)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Write-Host "  SCRIPT EXISTENCE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-PathExists -Name "05-verify-quality.ps1 exists" -Path $scriptPath
Assert-ValidPowerShell -Name "05-verify-quality.ps1 is valid PowerShell" -Path $scriptPath

function Invoke-QualityGate {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    Push-Location $ProjectRoot
    try {
        $raw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath -TaskId "t_quality1" -Category "test" 2>$null
        return ($raw | ConvertFrom-Json)
    } finally {
        Pop-Location
    }
}

function New-QualityGateProject {
    param($QualityGate)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-test-quality-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $bot = Join-Path $root ".bot"
    $control = Join-Path $bot ".control"
    New-Item -ItemType Directory -Path $control -Force | Out-Null

    if ($null -ne $QualityGate) {
        @{ quality_gate = $QualityGate } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $control "settings.json") -Encoding UTF8
    }

    return $root
}

$prevDotbotHome = $env:DOTBOT_HOME
$env:DOTBOT_HOME = $repoRoot

try {
    Write-Host ""
    Write-Host "  DISABLED BY DEFAULT" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $disabledRoot = New-QualityGateProject -QualityGate $null
    try {
        $result = Invoke-QualityGate -ProjectRoot $disabledRoot
        Assert-True -Name "No project override: gate reports success" -Condition ($result.success -eq $true)
        Assert-Equal -Name "No project override: script field" -Expected "05-verify-quality.ps1" -Actual $result.script
        Assert-True -Name "No project override: details.enabled is false" -Condition ($result.details.enabled -eq $false)
    } finally {
        Remove-Item -LiteralPath $disabledRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  ENABLED BUT UNCONFIGURED" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $unconfiguredRoot = New-QualityGateProject -QualityGate @{ enabled = $true }
    try {
        $result = Invoke-QualityGate -ProjectRoot $unconfiguredRoot
        Assert-True -Name "Enabled without commands: gate reports success" -Condition ($result.success -eq $true)
        Assert-True -Name "Enabled without commands: message mentions unconfigured" `
            -Condition ($result.message -match 'no test_command/lint_command configured')
    } finally {
        Remove-Item -LiteralPath $unconfiguredRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  PASSING TEST + LINT COMMANDS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $passRoot = New-QualityGateProject -QualityGate @{
        enabled      = $true
        test_command = "exit 0"
        lint_command = "exit 0"
    }
    try {
        $result = Invoke-QualityGate -ProjectRoot $passRoot
        Assert-True -Name "Passing commands: gate reports success" -Condition ($result.success -eq $true)
        Assert-Equal -Name "Passing commands: two checks ran" -Expected 2 -Actual @($result.details.checks).Count
        Assert-Equal -Name "Passing commands: no failures reported" -Expected 0 -Actual @($result.failures).Count
    } finally {
        Remove-Item -LiteralPath $passRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  FAILING TEST COMMAND BLOCKS THE GATE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $failTestRoot = New-QualityGateProject -QualityGate @{
        enabled      = $true
        test_command = "exit 1"
        lint_command = "exit 0"
    }
    try {
        $result = Invoke-QualityGate -ProjectRoot $failTestRoot
        Assert-True -Name "Failing test command: gate reports failure" -Condition ($result.success -eq $false)
        Assert-Equal -Name "Failing test command: exactly one failure" -Expected 1 -Actual @($result.failures).Count
        Assert-True -Name "Failing test command: failure names the test check" `
            -Condition ($result.failures[0].issue -match '^test command failed')
    } finally {
        Remove-Item -LiteralPath $failTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  FAILING LINT COMMAND BLOCKS THE GATE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $failLintRoot = New-QualityGateProject -QualityGate @{
        enabled      = $true
        test_command = "exit 0"
        lint_command = "exit 1"
    }
    try {
        $result = Invoke-QualityGate -ProjectRoot $failLintRoot
        Assert-True -Name "Failing lint command: gate reports failure" -Condition ($result.success -eq $false)
        Assert-Equal -Name "Failing lint command: exactly one failure" -Expected 1 -Actual @($result.failures).Count
        Assert-True -Name "Failing lint command: failure names the lint check" `
            -Condition ($result.failures[0].issue -match '^lint command failed')
    } finally {
        Remove-Item -LiteralPath $failLintRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  TEST_COMMAND ONLY (LINT UNCONFIGURED)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $testOnlyRoot = New-QualityGateProject -QualityGate @{
        enabled      = $true
        test_command = "exit 0"
    }
    try {
        $result = Invoke-QualityGate -ProjectRoot $testOnlyRoot
        Assert-True -Name "test_command only: gate reports success" -Condition ($result.success -eq $true)
        Assert-Equal -Name "test_command only: exactly one check ran" -Expected 1 -Actual @($result.details.checks).Count
        Assert-Equal -Name "test_command only: ran check is named 'test'" -Expected "test" -Actual $result.details.checks[0].name
    } finally {
        Remove-Item -LiteralPath $testOnlyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:DOTBOT_HOME = $prevDotbotHome
}

$success = Write-TestSummary -LayerName "Layer 1: Quality Gate"
if (-not $success) { exit 1 }
