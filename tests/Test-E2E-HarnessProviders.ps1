#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 4: Live harness provider smoke tests.
.DESCRIPTION
    Runs a minimal prompt through each installed CLI via Dotbot.Harness. Missing
    CLIs are skipped; installed CLIs must return the expected marker.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 4: E2E Harness Provider Smoke Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 4 prerequisites" -Status Fail -Message "dotbot not installed globally — set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 4: E2E Harness Providers"
    exit 1
}

$env:DOTBOT_HOME = $dotbotDir

$themeModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1"
$harnessModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psd1"
if (Test-Path $themeModule) { Import-Module $themeModule -Force }
Import-Module $harnessModule -Force

function Test-ClaudeCredentialAvailable {
    $hasApiKey = $null -ne $env:ANTHROPIC_API_KEY -and $env:ANTHROPIC_API_KEY.Length -gt 0
    $hasClaudeLogin = Test-Path (Join-Path $HOME ".claude")
    return ($hasApiKey -or $hasClaudeLogin)
}

function Invoke-LiveHarnessSmoke {
    param(
        [Parameter(Mandatory)][string]$HarnessName,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [int]$TimeoutSeconds = 180
    )

    $config = $null
    try {
        $config = Get-HarnessConfig -Name $HarnessName
    } catch {
        Write-TestResult -Name "$HarnessName provider config loads" -Status Fail -Message $_.Exception.Message
        return
    }

    $command = Get-Command $config.executable -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        Write-TestResult -Name "$HarnessName live smoke" -Status Skip -Message "$($config.executable) CLI not installed"
        return
    }

    if ($HarnessName -eq "claude" -and -not (Test-ClaudeCredentialAvailable)) {
        Write-TestResult -Name "$HarnessName live smoke" -Status Skip -Message "No Claude credentials (set ANTHROPIC_API_KEY or run 'claude login')"
        return
    }

    $testProject = New-TestProject -Prefix "dotbot-test-harness-$HarnessName"
    New-Item -Path (Join-Path $testProject ".bot/.control") -ItemType Directory -Force | Out-Null
    $activityLog = Join-Path $testProject ".bot/.control/activity.jsonl"
    $prompt = "Reply with exactly $ExpectedMarker and nothing else. Do not inspect files. Do not run tools."

    try {
        if (Test-Path $activityLog) { Remove-Item -Path $activityLog -Force }

        $job = Start-Job -ScriptBlock {
            param($RepoRoot, $ModulePath, $ThemeModulePath, $Provider, $PromptText, $ProjectDir)
            $env:DOTBOT_HOME = $RepoRoot
            Set-Location $ProjectDir
            if (Test-Path $ThemeModulePath) { Import-Module $ThemeModulePath -Force }
            Import-Module $ModulePath -Force
            Invoke-HarnessStream -Prompt $PromptText -Model "fast" -HarnessName $Provider -WorkingDirectory $ProjectDir *>&1 | Out-String
        } -ArgumentList $dotbotDir, $harnessModule, $themeModule, $HarnessName, $prompt, $testProject

        $job | Wait-Job -Timeout $TimeoutSeconds | Out-Null

        if ($job.State -eq "Running") {
            $job | Stop-Job
            Write-TestResult -Name "$HarnessName live smoke returns marker" -Status Fail -Message "Timed out after ${TimeoutSeconds}s"
            return
        }

        $output = ($job | Receive-Job *>&1 | Out-String)
        if ($job.State -ne "Completed") {
            Write-TestResult -Name "$HarnessName live smoke completes" -Status Fail -Message "Job state: $($job.State)`n$output"
            return
        }

        if (-not (Test-Path $activityLog)) {
            Write-TestResult -Name "$HarnessName live smoke returns marker" -Status Fail -Message "No activity log was written. Output: $output"
            return
        }

        $activity = Get-Content $activityLog -Raw
        Assert-True -Name "$HarnessName live smoke returns marker" `
            -Condition ($activity -match [regex]::Escape($ExpectedMarker)) `
            -Message "Expected marker '$ExpectedMarker' in activity log. Output: $output`nActivity: $activity"
    } finally {
        if ($job) { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
        Remove-TestProject -Path $testProject
    }
}

Write-Host "  LIVE PROVIDERS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "    Missing CLIs are skipped; installed CLIs must answer through Dotbot.Harness." -ForegroundColor DarkGray
Write-Host ""

Invoke-LiveHarnessSmoke -HarnessName "claude" -ExpectedMarker "DOTBOT_CLAUDE_LIVE_OK"
Invoke-LiveHarnessSmoke -HarnessName "codex" -ExpectedMarker "DOTBOT_CODEX_LIVE_OK"
Invoke-LiveHarnessSmoke -HarnessName "opencode" -ExpectedMarker "DOTBOT_OPENCODE_LIVE_OK"
Invoke-LiveHarnessSmoke -HarnessName "antigravity" -ExpectedMarker "DOTBOT_ANTIGRAVITY_LIVE_OK"

Write-Host ""

$allPassed = Write-TestSummary -LayerName "Layer 4: E2E Harness Providers"

if (-not $allPassed) {
    exit 1
}
