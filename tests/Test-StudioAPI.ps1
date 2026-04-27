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
# REGISTRY WORKFLOW DISCOVERY
# ===================================================================

Write-Host ""
Write-Host "  REGISTRY WORKFLOW DISCOVERY" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

# Build a fake registry structure under a temporary dotbot home
$tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-registry-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$tempWorkflows = Join-Path $tempHome 'workflows'
$tempRegistries = Join-Path $tempHome 'registries'
New-Item -ItemType Directory -Force -Path $tempWorkflows | Out-Null
New-Item -ItemType Directory -Force -Path $tempRegistries | Out-Null

# Create a mock registry with one workflow
$mockRegName = 'TestRegistry'
$mockWfName = 'test-workflow'
$mockRegWfDir = Join-Path $tempRegistries $mockRegName 'workflows' $mockWfName
New-Item -ItemType Directory -Force -Path $mockRegWfDir | Out-Null
Set-Content -Path (Join-Path $mockRegWfDir 'workflow.yaml') -Value @"
name: Test Workflow
version: 1.0.0
description: A test registry workflow
tasks: []
"@ -Encoding UTF8

# Write registries.json
Set-Content -Path (Join-Path $tempHome 'registries.json') -Value (@{
    registries = @(@{
        name = $mockRegName
        source = 'https://example.com/test.git'
        auto_update = $true
        branch = 'main'
        type = 'git'
    })
} | ConvertTo-Json -Depth 5) -Encoding UTF8

# Re-initialize module with the temp home as parent
$tempStaticReg = Join-Path $tempHome 'static'
New-Item -ItemType Directory -Force -Path $tempStaticReg | Out-Null
Initialize-StudioAPI -WorkflowsDir $tempWorkflows -StaticRoot $tempStaticReg

# --- Test: Get-RegistryWorkflows returns registry workflows ---
try {
    $regWorkflows = @(& $studioModule { Get-RegistryWorkflows })
    if ($regWorkflows.Count -ge 1) {
        Write-TestResult -Name "Get-RegistryWorkflows returns registry workflows" -Status Pass
    } else {
        Write-TestResult -Name "Get-RegistryWorkflows returns registry workflows" -Status Fail -Message "Expected at least 1 workflow, got $($regWorkflows.Count)"
    }
} catch {
    Write-TestResult -Name "Get-RegistryWorkflows returns registry workflows" -Status Fail -Message $_.Exception.Message
}

# --- Test: Registry workflows include registry name in folder field ---
try {
    $regWorkflows = @(& $studioModule { Get-RegistryWorkflows })
    $first = $regWorkflows[0]
    $expectedFolder = "${mockRegName}:${mockWfName}"
    if ($first.folder -eq $expectedFolder) {
        Write-TestResult -Name "Registry workflow folder uses 'Registry:name' format" -Status Pass
    } else {
        Write-TestResult -Name "Registry workflow folder uses 'Registry:name' format" -Status Fail -Message "Expected '$expectedFolder', got '$($first.folder)'"
    }
} catch {
    Write-TestResult -Name "Registry workflow folder uses 'Registry:name' format" -Status Fail -Message $_.Exception.Message
}

# --- Test: Registry workflows include registry field ---
try {
    $regWorkflows = @(& $studioModule { Get-RegistryWorkflows })
    $first = $regWorkflows[0]
    if ($first.registry -eq $mockRegName) {
        Write-TestResult -Name "Registry workflow includes registry field" -Status Pass
    } else {
        Write-TestResult -Name "Registry workflow includes registry field" -Status Fail -Message "Expected '$mockRegName', got '$($first.registry)'"
    }
} catch {
    Write-TestResult -Name "Registry workflow includes registry field" -Status Fail -Message $_.Exception.Message
}

# --- Test: Registry workflows include YAML content ---
try {
    $regWorkflows = @(& $studioModule { Get-RegistryWorkflows })
    $first = $regWorkflows[0]
    if ($first.yaml -and $first.yaml -match 'Test Workflow') {
        Write-TestResult -Name "Registry workflow includes YAML content" -Status Pass
    } else {
        Write-TestResult -Name "Registry workflow includes YAML content" -Status Fail -Message "YAML was null or missing expected content"
    }
} catch {
    Write-TestResult -Name "Registry workflow includes YAML content" -Status Fail -Message $_.Exception.Message
}

# --- Test: Get-RegistryWorkflows returns empty when no registries.json ---
$emptyHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-empty-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
try {
    $emptyWf = Join-Path $emptyHome 'workflows'
    $emptyStatic = Join-Path $emptyHome 'static'
    New-Item -ItemType Directory -Force -Path $emptyWf | Out-Null
    New-Item -ItemType Directory -Force -Path $emptyStatic | Out-Null
    Initialize-StudioAPI -WorkflowsDir $emptyWf -StaticRoot $emptyStatic
    $emptyResult = @(& $studioModule { Get-RegistryWorkflows })
    if ($emptyResult.Count -eq 0) {
        Write-TestResult -Name "Get-RegistryWorkflows returns empty when no registries.json" -Status Pass
    } else {
        Write-TestResult -Name "Get-RegistryWorkflows returns empty when no registries.json" -Status Fail -Message "Expected 0, got $($emptyResult.Count)"
    }
} catch {
    Write-TestResult -Name "Get-RegistryWorkflows returns empty when no registries.json" -Status Fail -Message $_.Exception.Message
} finally {
    Remove-Item -Path $emptyHome -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Test: Get-RegistryWorkflows returns empty when registries.json is malformed ---
$malformedHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-malformed-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
try {
    $malformedWf = Join-Path $malformedHome 'workflows'
    $malformedStatic = Join-Path $malformedHome 'static'
    New-Item -ItemType Directory -Force -Path $malformedWf | Out-Null
    New-Item -ItemType Directory -Force -Path $malformedStatic | Out-Null
    Set-Content -Path (Join-Path $malformedHome 'registries.json') -Value 'NOT VALID JSON {{{' -Encoding UTF8
    Initialize-StudioAPI -WorkflowsDir $malformedWf -StaticRoot $malformedStatic
    $malformedResult = @(& $studioModule { Get-RegistryWorkflows })
    if ($malformedResult.Count -eq 0) {
        Write-TestResult -Name "Get-RegistryWorkflows returns empty when registries.json is malformed" -Status Pass
    } else {
        Write-TestResult -Name "Get-RegistryWorkflows returns empty when registries.json is malformed" -Status Fail -Message "Expected 0, got $($malformedResult.Count)"
    }
} catch {
    Write-TestResult -Name "Get-RegistryWorkflows returns empty when registries.json is malformed" -Status Fail -Message "Should not throw: $($_.Exception.Message)"
} finally {
    Remove-Item -Path $malformedHome -Recurse -Force -ErrorAction SilentlyContinue
}

# ===================================================================
# REGISTRY WORKFLOW PATH RESOLUTION
# ===================================================================

Write-Host ""
Write-Host "  REGISTRY WORKFLOW PATH RESOLUTION" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

# Re-initialize to the mock registry home
Initialize-StudioAPI -WorkflowsDir $tempWorkflows -StaticRoot $tempStaticReg

# --- Test: Get-RegistryWorkflowDir resolves valid registry:workflow ---
try {
    $regDir = & $studioModule { param($r, $w) Get-RegistryWorkflowDir -RegistryName $r -WorkflowName $w } $mockRegName $mockWfName
    if ($regDir -and (Test-Path $regDir)) {
        Write-TestResult -Name "Get-RegistryWorkflowDir resolves valid registry:workflow" -Status Pass
    } else {
        Write-TestResult -Name "Get-RegistryWorkflowDir resolves valid registry:workflow" -Status Fail -Message "Path '$regDir' does not exist"
    }
} catch {
    Write-TestResult -Name "Get-RegistryWorkflowDir resolves valid registry:workflow" -Status Fail -Message $_.Exception.Message
}

# --- Test: Get-RegistryWorkflowDir rejects path traversal ---
$traversalCases = @(
    @{ Reg = '..';       Wf = 'test';     Label = 'registry name is ..' },
    @{ Reg = 'TestReg';  Wf = '../etc';   Label = 'workflow name traversal' },
    @{ Reg = 'foo/bar';  Wf = 'test';     Label = 'slash in registry name' },
    @{ Reg = '';          Wf = 'test';     Label = 'empty registry name' },
    @{ Reg = 'TestReg';  Wf = '';         Label = 'empty workflow name' }
)

foreach ($case in $traversalCases) {
    try {
        $result = & $studioModule { param($r, $w) Get-RegistryWorkflowDir -RegistryName $r -WorkflowName $w } $case.Reg $case.Wf
        if ($null -eq $result) {
            Write-TestResult -Name "Reject registry path: $($case.Label)" -Status Pass
        } else {
            Write-TestResult -Name "Reject registry path: $($case.Label)" -Status Fail -Message "Expected null but got '$result'"
        }
    } catch {
        # Exceptions are also acceptable rejections
        Write-TestResult -Name "Reject registry path: $($case.Label)" -Status Pass
    }
}

# --- Test: Test-WorkflowExists resolves registry:workflow names ---
try {
    $exists = & $studioModule { param($n) Test-WorkflowExists -Name $n } "${mockRegName}:${mockWfName}"
    if ($exists) {
        Write-TestResult -Name "Test-WorkflowExists resolves registry:workflow format" -Status Pass
    } else {
        Write-TestResult -Name "Test-WorkflowExists resolves registry:workflow format" -Status Fail -Message "Returned false for existing registry workflow"
    }
} catch {
    Write-TestResult -Name "Test-WorkflowExists resolves registry:workflow format" -Status Fail -Message $_.Exception.Message
}

# --- Test: Test-WorkflowExists returns false for non-existent registry workflow ---
try {
    $exists = & $studioModule { param($n) Test-WorkflowExists -Name $n } "FakeRegistry:nonexistent"
    if (-not $exists) {
        Write-TestResult -Name "Test-WorkflowExists returns false for non-existent registry workflow" -Status Pass
    } else {
        Write-TestResult -Name "Test-WorkflowExists returns false for non-existent registry workflow" -Status Fail -Message "Returned true for non-existent workflow"
    }
} catch {
    Write-TestResult -Name "Test-WorkflowExists returns false for non-existent registry workflow" -Status Fail -Message $_.Exception.Message
}

# ===================================================================
# REGISTRY SAVE-AS (copy to local workflows)
# ===================================================================

Write-Host ""
Write-Host "  REGISTRY SAVE-AS (copy to local)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

# Enrich the mock registry workflow with realistic content
$mockPromptDir = Join-Path $mockRegWfDir 'recipes' 'prompts'
$mockAgentDir  = Join-Path $mockRegWfDir 'recipes' 'agents' 'test-agent'
$mockSkillDir  = Join-Path $mockRegWfDir 'recipes' 'skills' 'test-skill'
New-Item -ItemType Directory -Force -Path $mockPromptDir | Out-Null
New-Item -ItemType Directory -Force -Path $mockAgentDir  | Out-Null
New-Item -ItemType Directory -Force -Path $mockSkillDir  | Out-Null
Set-Content -Path (Join-Path $mockRegWfDir 'manifest.yaml')            -Value 'name: test-workflow' -Encoding UTF8
Set-Content -Path (Join-Path $mockRegWfDir 'on-install.ps1')           -Value '# on-install stub' -Encoding UTF8
Set-Content -Path (Join-Path $mockPromptDir '00-launch.md')         -Value '# Launch prompt' -Encoding UTF8
Set-Content -Path (Join-Path $mockAgentDir 'agent.md')                 -Value '# Test agent' -Encoding UTF8
Set-Content -Path (Join-Path $mockSkillDir 'SKILL.md')                 -Value '# Test skill' -Encoding UTF8

# Simulate Save As: copy from registry to local workflows folder
$localCopyName = 'test-workflow-local'
$localCopyDir  = Join-Path $tempWorkflows $localCopyName

try {
    & $studioModule { param($src, $dst) Copy-DirectoryRecursive -Source $src -Destination $dst } $mockRegWfDir $localCopyDir

    $expectedFiles = @(
        'workflow.yaml',
        'manifest.yaml',
        'on-install.ps1',
        (Join-Path 'recipes' 'prompts' '00-launch.md'),
        (Join-Path 'recipes' 'agents' 'test-agent' 'agent.md'),
        (Join-Path 'recipes' 'skills' 'test-skill' 'SKILL.md')
    )

    $allPresent = $true
    $missingFiles = @()
    foreach ($relPath in $expectedFiles) {
        $fullPath = Join-Path $localCopyDir $relPath
        if (-not (Test-Path $fullPath)) {
            $allPresent = $false
            $missingFiles += $relPath
        }
    }

    if ($allPresent) {
        Write-TestResult -Name "Save As copies all workflow files from registry to local" -Status Pass
    } else {
        Write-TestResult -Name "Save As copies all workflow files from registry to local" -Status Fail -Message "Missing: $($missingFiles -join ', ')"
    }

    # Spot-check content
    $promptContent = Get-Content -Path (Join-Path $localCopyDir 'recipes' 'prompts' '00-launch.md') -Raw -Encoding UTF8
    if ($promptContent -match 'Launch prompt') {
        Write-TestResult -Name "Save As preserves file content" -Status Pass
    } else {
        Write-TestResult -Name "Save As preserves file content" -Status Fail -Message "Content mismatch in copied prompt file"
    }
} catch {
    Write-TestResult -Name "Save As copies all workflow files from registry to local" -Status Fail -Message $_.Exception.Message
}

# ===================================================================
# Cleanup
# ===================================================================

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $tempHome -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-TestSummary -LayerName "Layer 2: StudioAPI"

$results = Get-TestResults
if ($results.Failed -gt 0) { exit 1 }
