#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Unit tests for StudioAPI.psm1 path sanitization.
.DESCRIPTION
    Tests Get-SafeWorkflowDir and verifies that path traversal attempts
    are correctly rejected across all security-critical code paths.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: StudioAPI Path Sanitization Tests" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "studio-ui")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally or studio-ui missing - run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: StudioAPI"
    exit 1
}

$modulePath = Join-Path $dotbotDir 'studio-ui' 'StudioAPI.psm1'

# ===================================================================
# MODULE LOADING
# ===================================================================

Write-Host "  MODULE LOADING" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

try {
    Import-Module $modulePath -Force
    Write-TestResult -Name "StudioAPI.psm1 loads without error" -Status Pass
} catch {
    Write-TestResult -Name "StudioAPI.psm1 loads without error" -Status Fail -Message $_.Exception.Message
    Write-TestSummary -LayerName "Layer 2: StudioAPI"
    exit 1
}

# Create a temp workflows directory for testing
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-studio-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
$tempStatic = Join-Path $tempDir "static"
New-Item -ItemType Directory -Force -Path $tempStatic | Out-Null

# Initialize the module with our temp directory
Initialize-StudioAPI -WorkflowsDir $tempDir -StaticRoot $tempStatic

# Get a reference to the module for calling internal functions
$studioModule = Get-Module StudioAPI

# ===================================================================
# Get-SafeWorkflowDir — VALID NAMES (should succeed)
# ===================================================================

Write-Host ""
Write-Host "  VALID WORKFLOW NAMES" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$validNames = @(
    'my-workflow',
    'test.v2',
    'workflow_1',
    'My-Project',
    'simple',
    'v2.0.1-beta'
)

foreach ($name in $validNames) {
    try {
        $result = & $studioModule { param($n) Get-SafeWorkflowDir -Name $n } $name
        $isUnderRoot = $result.StartsWith([System.IO.Path]::GetFullPath($tempDir))
        if ($isUnderRoot) {
            Write-TestResult -Name "Valid name '$name' returns path under workflows root" -Status Pass
        } else {
            Write-TestResult -Name "Valid name '$name' returns path under workflows root" -Status Fail -Message "Path '$result' escapes workflows root"
        }
    } catch {
        Write-TestResult -Name "Valid name '$name' returns path under workflows root" -Status Fail -Message $_.Exception.Message
    }
}

# ===================================================================
# Get-SafeWorkflowDir — INVALID NAMES (should throw)
# ===================================================================

Write-Host ""
Write-Host "  INVALID WORKFLOW NAMES (must be rejected)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$invalidNames = @(
    @{ Name = '..';                 Label = 'double dot (..)' },
    @{ Name = '.';                  Label = 'single dot (.)' },
    @{ Name = '../../etc';          Label = 'traversal (../../etc)' },
    @{ Name = 'foo/bar';            Label = 'path with slash (foo/bar)' },
    @{ Name = 'foo\bar';            Label = 'path with backslash (foo\bar)' },
    @{ Name = '';                   Label = 'empty string' },
    @{ Name = '   ';                Label = 'whitespace only' },
    @{ Name = 'bad$name';           Label = 'dollar sign (bad$name)' },
    @{ Name = 'semi;colon';         Label = 'semicolon (semi;colon)' },
    @{ Name = 'has space';          Label = 'space in name (has space)' },
    @{ Name = '%2e%2e';             Label = 'encoded dots (%2e%2e)' }
)

foreach ($case in $invalidNames) {
    try {
        $null = & $studioModule { param($n) Get-SafeWorkflowDir -Name $n } $case.Name
        Write-TestResult -Name "Reject $($case.Label)" -Status Fail -Message "Expected exception but call succeeded"
    } catch {
        Write-TestResult -Name "Reject $($case.Label)" -Status Pass
    }
}

# ===================================================================
# Cleanup
# ===================================================================

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-TestSummary -LayerName "Layer 2: StudioAPI"

$results = Get-TestResults
if ($results.Failed -gt 0) { exit 1 }
