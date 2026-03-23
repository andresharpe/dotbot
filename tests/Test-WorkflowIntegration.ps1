#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Integration tests for workflow manifest features in initialized projects.
.DESCRIPTION
    Tests workflow manifest integration with init'd projects: form.modes
    condition evaluation, manifest-driven preflight checks, kickstart status,
    Get-ActiveWorkflowManifest resolution, and workflow.yaml presence.
    Requires dotbot to be installed globally.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir
$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Workflow Integration Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Stale install detection: if repo source is newer than installed copy (or not installed), reinstall
$needsInstall = -not (Test-Path (Join-Path $dotbotDir "workflows\default"))
if (-not $needsInstall) {
    $devNewest = (Get-ChildItem "$repoRoot\workflows","$repoRoot\stacks" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $installNewest = (Get-ChildItem "$dotbotDir\workflows","$dotbotDir\stacks" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($devNewest -gt $installNewest) { $needsInstall = $true }
}
if ($needsInstall) {
    Write-Host "  Auto-installing from dev source..." -ForegroundColor Yellow
    & pwsh -NoProfile -File "$repoRoot\install.ps1" 2>&1 | Out-Null
    Write-Host ""
}

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "workflows\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Workflow Integration"
    exit 1
}

# Check prerequisite: powershell-yaml
$yamlModule = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
if (-not $yamlModule) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "powershell-yaml module not installed"
    Write-TestSummary -LayerName "Layer 2: Workflow Integration"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW.YAML PRESENCE AFTER INIT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKFLOW.YAML AFTER INIT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Default profile init → workflow.yaml should be copied
$testProjectDefault = New-TestProject
try {
    Push-Location $testProjectDefault
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    Pop-Location

    $botDirDefault = Join-Path $testProjectDefault ".bot"
    $workflowYaml = Join-Path $botDirDefault "workflow.yaml"
    Assert-PathExists -Name "Default init: workflow.yaml copied to .bot/" -Path $workflowYaml

    if (Test-Path $workflowYaml) {
        $raw = Get-Content $workflowYaml -Raw
        Assert-True -Name "Default init: workflow.yaml has tasks" `
            -Condition ($raw -match 'tasks:') -Message "No tasks key found"
        Assert-True -Name "Default init: workflow.yaml has form" `
            -Condition ($raw -match 'form:') -Message "No form key found"
    }
} finally {
    Remove-TestProject -Path $testProjectDefault
}

# Kickstart-via-jira profile init → root workflow.yaml must remain default
$kickstartViaJiraProfile = Join-Path $dotbotDir "workflows\kickstart-via-jira"
if (Test-Path $kickstartViaJiraProfile) {
    $testProjectJira = New-TestProject
    try {
        Push-Location $testProjectJira
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-jira 2>&1 | Out-Null
        Pop-Location

        $botDirJira = Join-Path $testProjectJira ".bot"

        # Root workflow.yaml must still be the default manifest (not overwritten by installed workflow)
        $rootWorkflowYaml = Join-Path $botDirJira "workflow.yaml"
        Assert-PathExists -Name "Jira init: root workflow.yaml exists" -Path $rootWorkflowYaml
        if (Test-Path $rootWorkflowYaml) {
            $rootRaw = Get-Content $rootWorkflowYaml -Raw
            Assert-True -Name "Jira init: root workflow.yaml is default (has 'name: default')" `
                -Condition ($rootRaw -match 'name:\s*default') `
                -Message "Root workflow.yaml was overwritten by installed workflow"
            Assert-True -Name "Jira init: root workflow.yaml has form (default feature)" `
                -Condition ($rootRaw -match 'form:') -Message "No form key — not the default manifest"
        }

        # Installed workflow must be in workflows/<name>/ with its own manifest
        $installedWfYaml = Join-Path $botDirJira "workflows\kickstart-via-jira\workflow.yaml"
        Assert-PathExists -Name "Jira init: installed workflow.yaml in workflows/kickstart-via-jira/" -Path $installedWfYaml
        if (Test-Path $installedWfYaml) {
            $wfRaw = Get-Content $installedWfYaml -Raw
            Assert-True -Name "Jira init: installed manifest has requires" `
                -Condition ($wfRaw -match 'requires:') -Message "No requires key found"
            Assert-True -Name "Jira init: installed manifest has domain" `
                -Condition ($wfRaw -match 'domain:') -Message "No domain key found"
        }
    } finally {
        Remove-TestProject -Path $testProjectJira
    }
} else {
    Write-TestResult -Name "Jira init workflow.yaml tests" -Status Skip -Message "kickstart-via-jira profile not found"
}

# Kickstart-via-pr profile init → workflow.yaml
$kickstartViaPrProfile = Join-Path $dotbotDir "workflows\kickstart-via-pr"
if (Test-Path $kickstartViaPrProfile) {
    $testProjectPr = New-TestProject
    try {
        Push-Location $testProjectPr
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-pr 2>&1 | Out-Null
        Pop-Location

        $botDirPr = Join-Path $testProjectPr ".bot"
        $prWorkflowYaml = Join-Path $botDirPr "workflow.yaml"
        Assert-PathExists -Name "PR init: workflow.yaml copied to .bot/" -Path $prWorkflowYaml
    } finally {
        Remove-TestProject -Path $testProjectPr
    }
} else {
    Write-TestResult -Name "PR init workflow.yaml tests" -Status Skip -Message "kickstart-via-pr profile not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GET-ACTIVEWORKFLOWMANIFEST RESOLUTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GET-ACTIVEWORKFLOWMANIFEST" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$testProjectManifest = New-TestProject
try {
    Push-Location $testProjectManifest
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    Pop-Location

    $botDirManifest = Join-Path $testProjectManifest ".bot"

    # Dot-source the workflow manifest module from the installed bot
    . (Join-Path $botDirManifest "systems\runtime\modules\workflow-manifest.ps1")

    # Resolution from .bot/workflow.yaml (profile-installed)
    $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirManifest
    Assert-True -Name "Get-ActiveWorkflowManifest finds manifest" `
        -Condition ($null -ne $manifest) -Message "Manifest not found"

    if ($manifest) {
        Assert-Equal -Name "Resolved manifest name is 'default'" `
            -Expected "default" -Actual $manifest.name
        Assert-True -Name "Resolved manifest has tasks" `
            -Condition ($manifest.tasks -and $manifest.tasks.Count -gt 0) -Message "No tasks"
        Assert-True -Name "Resolved manifest has form" `
            -Condition ($null -ne $manifest.form) -Message "No form"
    }

    # No manifest → returns null
    $noManifestDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-nomanifest-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Path $noManifestDir -Force | Out-Null
    try {
        $nullResult = Get-ActiveWorkflowManifest -BotRoot $noManifestDir
        Assert-True -Name "No manifest returns null" `
            -Condition ($null -eq $nullResult) -Message "Expected null"
    } finally {
        Remove-Item -Path $noManifestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Installed workflow takes precedence over root workflow.yaml
    $wfDir = Join-Path $botDirManifest "workflows\test-workflow"
    New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
    @"
name: test-workflow
version: "1.0"
description: A test workflow
min_dotbot_version: "3.5"
tasks:
  - name: "Test Task"
    type: prompt
    priority: 1
"@ | Set-Content (Join-Path $wfDir "workflow.yaml")

    $installedManifest = Get-ActiveWorkflowManifest -BotRoot $botDirManifest
    Assert-True -Name "Installed workflow takes precedence" `
        -Condition ($installedManifest.name -eq "test-workflow") `
        -Message "Expected 'test-workflow', got '$($installedManifest.name)'"

    # Clean up installed workflow to avoid affecting later tests
    Remove-Item -Path (Join-Path $botDirManifest "workflows") -Recurse -Force -ErrorAction SilentlyContinue

} finally {
    Remove-TestProject -Path $testProjectManifest
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# FORM.MODES CONDITION EVALUATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FORM.MODES CONDITIONS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$testProjectModes = New-TestProject
try {
    Push-Location $testProjectModes
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    Pop-Location

    $botDirModes = Join-Path $testProjectModes ".bot"

    # Dot-source workflow manifest module
    . (Join-Path $botDirModes "systems\runtime\modules\workflow-manifest.ps1")

    $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirModes
    if (-not $manifest -or -not $manifest.form -or -not $manifest.form.modes) {
        Write-TestResult -Name "form.modes tests" -Status Skip -Message "No form.modes in manifest"
    } else {
        $modes = $manifest.form.modes

        # Current default workflow has 2 modes based on product.md:
        #   new_project: condition !.bot/workspace/product/product.md
        #   has_docs:    condition .bot/workspace/product/product.md

        # State 1: Fresh project — no product.md → new_project mode
        $matchedMode = $null
        foreach ($mode in $modes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $testProjectModes -Condition $modeCondition) {
                $matchedMode = if ($mode -is [System.Collections.IDictionary]) { $mode['id'] } else { $mode.id }
                break
            }
        }
        Assert-Equal -Name "Fresh project without product.md matches new_project mode" `
            -Expected "new_project" -Actual $matchedMode

        # State 2: Create product.md → has_docs should match
        $productDir = Join-Path $botDirModes "workspace\product"
        if (-not (Test-Path $productDir)) { New-Item -ItemType Directory -Path $productDir -Force | Out-Null }
        "# Product" | Set-Content (Join-Path $productDir "product.md")

        $matchedMode2 = $null
        foreach ($mode in $modes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $testProjectModes -Condition $modeCondition) {
                $matchedMode2 = if ($mode -is [System.Collections.IDictionary]) { $mode['id'] } else { $mode.id }
                break
            }
        }
        Assert-Equal -Name "Project with product.md matches has_docs mode" `
            -Expected "has_docs" -Actual $matchedMode2

        # State 3: Remove product.md again → back to new_project
        Remove-Item (Join-Path $productDir "product.md") -Force

        $matchedMode3 = $null
        foreach ($mode in $modes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $testProjectModes -Condition $modeCondition) {
                $matchedMode3 = if ($mode -is [System.Collections.IDictionary]) { $mode['id'] } else { $mode.id }
                break
            }
        }
        Assert-Equal -Name "After removing product.md matches new_project mode" `
            -Expected "new_project" -Actual $matchedMode3
    }

} finally {
    Remove-TestProject -Path $testProjectModes
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# MANIFEST-DRIVEN PREFLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MANIFEST PREFLIGHT CHECKS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $kickstartViaJiraProfile) {
    $testProjectPreflight = New-TestProject
    try {
        Push-Location $testProjectPreflight
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-jira 2>&1 | Out-Null
        Pop-Location

        $botDirPreflight = Join-Path $testProjectPreflight ".bot"

        # Dot-source modules
        . (Join-Path $botDirPreflight "systems\runtime\modules\workflow-manifest.ps1")

        $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirPreflight
        Assert-True -Name "Jira manifest loaded for preflight" `
            -Condition ($null -ne $manifest) -Message "No manifest"

        if ($manifest -and $manifest.requires) {
            $checks = @(Convert-ManifestRequiresToPreflightChecks -Requires $manifest.requires)

            Assert-True -Name "Jira preflight generates checks" `
                -Condition ($checks.Count -gt 0) -Message "No checks generated"

            $envVarChecks = @($checks | Where-Object { $_.type -eq 'env_var' })
            Assert-True -Name "Jira preflight has env_var checks" `
                -Condition ($envVarChecks.Count -ge 4) `
                -Message "Expected at least 4 env_var checks, got $($envVarChecks.Count)"

            $mcpChecks = @($checks | Where-Object { $_.type -eq 'mcp_server' })
            Assert-True -Name "Jira preflight has mcp_server checks" `
                -Condition ($mcpChecks.Count -ge 2) `
                -Message "Expected at least 2 mcp_server checks, got $($mcpChecks.Count)"

            $cliChecks = @($checks | Where-Object { $_.type -eq 'cli_tool' })
            Assert-True -Name "Jira preflight has cli_tool checks" `
                -Condition ($cliChecks.Count -ge 2) `
                -Message "Expected at least 2 cli_tool checks, got $($cliChecks.Count)"

            # Verify all checks have name and type
            foreach ($check in $checks) {
                Assert-True -Name "Preflight check has type: $($check.name)" `
                    -Condition (-not [string]::IsNullOrEmpty($check.type)) -Message "Missing type"
                Assert-True -Name "Preflight check has name: $($check.name)" `
                    -Condition (-not [string]::IsNullOrEmpty($check.name)) -Message "Missing name"
            }
        }
    } finally {
        Remove-TestProject -Path $testProjectPreflight
    }
} else {
    Write-TestResult -Name "Manifest preflight tests" -Status Skip -Message "kickstart-via-jira profile not found"
}

# Default profile should have empty/minimal preflight
$testProjectDefaultPreflight = New-TestProject
try {
    Push-Location $testProjectDefaultPreflight
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    Pop-Location

    $botDirDefaultPreflight = Join-Path $testProjectDefaultPreflight ".bot"
    . (Join-Path $botDirDefaultPreflight "systems\runtime\modules\workflow-manifest.ps1")

    $defaultManifest = Get-ActiveWorkflowManifest -BotRoot $botDirDefaultPreflight
    if ($defaultManifest -and $defaultManifest.requires) {
        $defaultChecks = @(Convert-ManifestRequiresToPreflightChecks -Requires $defaultManifest.requires)
        Assert-Equal -Name "Default profile has no preflight checks" `
            -Expected 0 -Actual $defaultChecks.Count
    } else {
        Assert-True -Name "Default profile has no requires block" -Condition $true
    }
} finally {
    Remove-TestProject -Path $testProjectDefaultPreflight
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# MANIFEST TASKS → PHASES INTEGRATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MANIFEST TASKS → PHASES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$testProjectPhases = New-TestProject
try {
    Push-Location $testProjectPhases
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    Pop-Location

    $botDirPhases = Join-Path $testProjectPhases ".bot"
    . (Join-Path $botDirPhases "systems\runtime\modules\workflow-manifest.ps1")

    $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirPhases

    if ($manifest -and $manifest.tasks -and $manifest.tasks.Count -gt 0) {
        $phases = @(Convert-ManifestTasksToPhases -Tasks $manifest.tasks)

        Assert-Equal -Name "Phase count matches manifest task count" `
            -Expected $manifest.tasks.Count -Actual $phases.Count

        # Verify each phase has id, name, type
        foreach ($phase in $phases) {
            Assert-True -Name "Phase '$($phase.name)' has id" `
                -Condition (-not [string]::IsNullOrEmpty($phase.id)) -Message "Missing id"
            Assert-True -Name "Phase '$($phase.name)' has name" `
                -Condition (-not [string]::IsNullOrEmpty($phase.name)) -Message "Missing name"
            Assert-True -Name "Phase '$($phase.name)' has type" `
                -Condition (-not [string]::IsNullOrEmpty($phase.type)) -Message "Missing type"
        }

        # Phase IDs should be unique
        $phaseIds = @($phases | ForEach-Object { $_.id })
        $uniqueIds = @($phaseIds | Sort-Object -Unique)
        Assert-Equal -Name "Phase IDs are unique" `
            -Expected $phaseIds.Count -Actual $uniqueIds.Count
    } else {
        Write-TestResult -Name "Phase integration" -Status Skip -Message "No manifest tasks found"
    }

} finally {
    Remove-TestProject -Path $testProjectPhases
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TASK CONDITION EVALUATION IN PIPELINE CONTEXT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  TASK CONDITIONS IN PIPELINE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$testProjectConditions = New-TestProject
try {
    Push-Location $testProjectConditions
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    Pop-Location

    $botDirCond = Join-Path $testProjectConditions ".bot"
    . (Join-Path $botDirCond "systems\runtime\modules\workflow-manifest.ps1")

    $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirCond

    if ($manifest -and $manifest.tasks) {
        # Test task conditions if any tasks have them
        $conditionedTasks = @($manifest.tasks | Where-Object { $_.condition })
        if ($conditionedTasks.Count -gt 0) {
            Assert-True -Name "Manifest has tasks with conditions" `
                -Condition $true

            foreach ($task in $conditionedTasks) {
                $condResult = Test-ManifestCondition -ProjectRoot $testProjectConditions -Condition $task.condition
                Write-TestResult -Name "Task '$($task.name)' condition evaluates without error" -Status Pass
            }
        } else {
            # Default workflow uses depends_on (not condition) — verify tasks have dependencies instead
            $tasksWithDeps = @($manifest.tasks | Where-Object { $_.depends_on -and $_.depends_on.Count -gt 0 })
            Assert-True -Name "Default manifest tasks use depends_on for ordering" `
                -Condition ($tasksWithDeps.Count -gt 0) `
                -Message "No tasks with depends_on found"
        }
    }

} finally {
    Remove-TestProject -Path $testProjectConditions
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Workflow Integration"

if (-not $allPassed) {
    exit 1
}
