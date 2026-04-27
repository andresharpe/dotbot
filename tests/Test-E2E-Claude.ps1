#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 4: End-to-end tests with real Claude CLI.
.DESCRIPTION
    Seeds a test project with a briefing file, runs the workflow-launch flow,
    and verifies product documents are created. Requires Claude credentials.
    Uses Haiku model to minimize cost.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 4: E2E Claude Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# CREDENTIAL CHECK
# ═══════════════════════════════════════════════════════════════════

$hasApiKey = $null -ne $env:ANTHROPIC_API_KEY -and $env:ANTHROPIC_API_KEY.Length -gt 0
$hasClaudeLogin = Test-Path (Join-Path $HOME ".claude")
$claudeAvailable = Get-Command claude -ErrorAction SilentlyContinue

if (-not $claudeAvailable) {
    Write-TestResult -Name "Layer 4 prerequisites" -Status Skip -Message "Claude CLI not installed"
    Write-TestSummary -LayerName "Layer 4: E2E Claude"
    exit 0
}

if (-not $hasApiKey -and -not $hasClaudeLogin) {
    Write-TestResult -Name "Layer 4 prerequisites" -Status Skip -Message "No Claude credentials (set ANTHROPIC_API_KEY or run 'claude login')"
    Write-TestSummary -LayerName "Layer 4: E2E Claude"
    exit 0
}

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 4 prerequisites" -Status Fail -Message "dotbot not installed globally"
    Write-TestSummary -LayerName "Layer 4: E2E Claude"
    exit 1
}

Write-Host "  SETUP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Create test project
$testProject = New-TestProject -Prefix "dotbot-test-e2e"
$botDir = Join-Path $testProject ".bot"

Push-Location $testProject
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
Pop-Location

Assert-PathExists -Name "E2E: .bot initialized" -Path $botDir

# Seed briefing file
$briefingDir = Join-Path $botDir "workspace\product\briefing"
if (-not (Test-Path $briefingDir)) {
    New-Item -ItemType Directory -Path $briefingDir -Force | Out-Null
}

$briefingContent = @"
# Test Project: Hello Health

A minimal web application that serves a single HTML page with a health check endpoint.

## Requirements
- A static HTML home page at / that says "Hello from dotbot!"
- A /health endpoint returning JSON: { "status": "ok" }
- Built with Python Flask (simple, no database needed)

## Tech Stack
- Python 3.12
- Flask
- No database

## Success Criteria
- Home page renders
- Health endpoint returns 200 with JSON
"@

$briefingContent | Set-Content -Path (Join-Path $briefingDir "requirements.md") -Encoding UTF8
Assert-PathExists -Name "E2E: Briefing file created" -Path (Join-Path $briefingDir "requirements.md")

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# LAUNCH: PRODUCT DOCS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  LAUNCH (product docs)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "    This may take 1-3 minutes..." -ForegroundColor DarkGray

# Import ClaudeCLI module
$claudeModule = Join-Path $dotbotDir "core/runtime/ClaudeCLI/ClaudeCLI.psm1"
$themeModule = Join-Path $dotbotDir "core/runtime/modules/DotBotTheme.psm1"

if (Test-Path $themeModule) { Import-Module $themeModule -Force }
Import-Module $claudeModule -Force

# Build a product planning prompt
$workflowPath = Join-Path $botDir "recipes\prompts\01-plan-product.md"
$workflowContent = if (Test-Path $workflowPath) { Get-Content $workflowPath -Raw } else { "" }

$launchPrompt = @"
You are a product planning assistant. Create foundational product documents for a project.

Follow this workflow:
$workflowContent

Read the briefing file at .bot/workspace/product/briefing/requirements.md for project details.

Create these files:
1. .bot/workspace/product/mission.md - Must start with ## Executive Summary
2. .bot/workspace/product/tech-stack.md
3. .bot/workspace/product/entity-model.md

Be concise. Write directly to the files. Do not ask questions.
"@

# Run with timeout (5 minutes)
$timeoutSeconds = 300
$completed = $false

try {
    Push-Location $testProject

    $job = Start-Job -ScriptBlock {
        param($module, $themeModule, $prompt, $projectDir)
        Set-Location $projectDir
        if (Test-Path $themeModule) { Import-Module $themeModule -Force }
        Import-Module $module -Force
        # Use Haiku for cheapest E2E test
        Invoke-ClaudeStream -Prompt $prompt -Model "haiku" *>&1
    } -ArgumentList $claudeModule, $themeModule, $launchPrompt, $testProject

    $job | Wait-Job -Timeout $timeoutSeconds | Out-Null

    if ($job.State -eq "Completed") {
        $completed = $true
    } elseif ($job.State -eq "Running") {
        $job | Stop-Job
        Write-TestResult -Name "E2E: Launch completed within timeout" -Status Fail -Message "Timed out after ${timeoutSeconds}s"
    } else {
        $jobErrors = $job | Receive-Job 2>&1
        Write-TestResult -Name "E2E: Launch completed" -Status Fail -Message "Job state: $($job.State)`nErrors: $($jobErrors -join "`n")"
    }

    $job | Remove-Job -Force -ErrorAction SilentlyContinue

    Pop-Location

} catch {
    Write-TestResult -Name "E2E: Launch execution" -Status Fail -Message $_.Exception.Message
    Pop-Location
}

if ($completed) {
    Write-TestResult -Name "E2E: Launch completed within timeout" -Status Pass
}

# Verify product docs were created
$productDir = Join-Path $botDir "workspace\product"
Assert-PathExists -Name "E2E: mission.md created" -Path (Join-Path $productDir "mission.md")
Assert-PathExists -Name "E2E: tech-stack.md created" -Path (Join-Path $productDir "tech-stack.md")
Assert-PathExists -Name "E2E: entity-model.md created" -Path (Join-Path $productDir "entity-model.md")

# Verify mission.md has Executive Summary
$missionPath = Join-Path $productDir "mission.md"
if (Test-Path $missionPath) {
    Assert-FileContains -Name "E2E: mission.md has Executive Summary" `
        -Path $missionPath `
        -Pattern "Executive Summary"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════

Remove-TestProject -Path $testProject

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 4: E2E Claude"

if (-not $allPassed) {
    exit 1
}
