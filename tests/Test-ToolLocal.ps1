#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Runs tool-local test.ps1 scripts inside an initialized project.
.DESCRIPTION
    Creates a temp project via dotbot init, sets $global:DotbotProjectRoot,
    then executes each MCP tool's test.ps1. Each test imports Test-Helpers.psm1
    and uses Assert-True/Assert-Equal for assertions.
    Also runs standalone tool tests from non-default workflows (kickstart-*)
    that create their own isolated test roots.
    Requires dotbot to be installed globally.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir
$repoRoot = Get-RepoRoot
$helpersPath = Join-Path $PSScriptRoot "Test-Helpers.psm1"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Tool-Local Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "workflows\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally"
    Write-TestSummary -LayerName "Layer 2: Tool-Local"
    exit 1
}

# --- Default workflow tools (need an initialized project) ---

$testProject = New-TestProject
$botDir = Join-Path $testProject ".bot"

Push-Location $testProject
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
Pop-Location

$toolsDir = Join-Path $botDir "systems\mcp\tools"
$defaultTests = Get-ChildItem -Path $toolsDir -Filter "test.ps1" -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object { $_.Directory.Name }

foreach ($testFile in $defaultTests) {
    $toolName = $testFile.Directory.Name

    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -Command @"
        `$global:DotbotProjectRoot = '$testProject'
        `$env:DOTBOT_TEST_HELPERS = '$helpersPath'
        & '$($testFile.FullName)' 2>&1
        exit `$LASTEXITCODE
"@ 2>&1

    if ($LASTEXITCODE -ne 0) {
        $errorLine = ($output | Out-String).Trim().Split("`n") |
            Where-Object { $_ -match 'Exception|Error|FAIL' } |
            Select-Object -First 1
        $msg = if ($errorLine) { $errorLine.Trim() } else { "Exit code $LASTEXITCODE" }
        Assert-True -Name "tool-local: $toolName" -Condition $false -Message $msg
    } else {
        Assert-True -Name "tool-local: $toolName" -Condition $true
    }
}

Remove-TestProject -Path $testProject

# --- Non-default workflow tools (standalone, create their own test roots) ---

$workflowDirs = Get-ChildItem -Path (Join-Path $repoRoot "workflows") -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "default" }

foreach ($wfDir in $workflowDirs) {
    $wfToolTests = Get-ChildItem -Path $wfDir.FullName -Filter "test.ps1" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'systems[\\/]mcp[\\/]tools[\\/]' } |
        Sort-Object { $_.Directory.Name }

    foreach ($testFile in $wfToolTests) {
        $toolName = "$($wfDir.Name)/$($testFile.Directory.Name)"

        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -Command @"
            `$env:DOTBOT_TEST_HELPERS = '$helpersPath'
            & '$($testFile.FullName)' 2>&1
            exit `$LASTEXITCODE
"@ 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorLine = ($output | Out-String).Trim().Split("`n") |
                Where-Object { $_ -match 'Exception|Error|FAIL' } |
                Select-Object -First 1
            $msg = if ($errorLine) { $errorLine.Trim() } else { "Exit code $LASTEXITCODE" }
            Assert-True -Name "tool-local: $toolName" -Condition $false -Message $msg
        } else {
            Assert-True -Name "tool-local: $toolName" -Condition $true
        }
    }
}

Write-Host ""

$allPassed = Write-TestSummary -LayerName "Layer 2: Tool-Local"

if (-not $allPassed) {
    exit 1
}
