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
$kickstartViaJiraProfile = Join-Path $dotbotDir "workflows\start-from-jira"
if (Test-Path $kickstartViaJiraProfile) {
    $testProjectJira = New-TestProject
    try {
        Push-Location $testProjectJira
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow start-from-jira 2>&1 | Out-Null
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
        $installedWfYaml = Join-Path $botDirJira "workflows\start-from-jira\workflow.yaml"
        Assert-PathExists -Name "Jira init: installed workflow.yaml in workflows/start-from-jira/" -Path $installedWfYaml
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
    Write-TestResult -Name "Jira init workflow.yaml tests" -Status Skip -Message "start-from-jira profile not found"
}

# Kickstart-via-pr profile init → workflow.yaml
$kickstartViaPrProfile = Join-Path $dotbotDir "workflows\start-from-pr"
if (Test-Path $kickstartViaPrProfile) {
    $testProjectPr = New-TestProject
    try {
        Push-Location $testProjectPr
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow start-from-pr 2>&1 | Out-Null
        Pop-Location

        $botDirPr = Join-Path $testProjectPr ".bot"
        $prWorkflowYaml = Join-Path $botDirPr "workflow.yaml"
        Assert-PathExists -Name "PR init: workflow.yaml copied to .bot/" -Path $prWorkflowYaml
    } finally {
        Remove-TestProject -Path $testProjectPr
    }
} else {
    Write-TestResult -Name "PR init workflow.yaml tests" -Status Skip -Message "start-from-pr profile not found"
}

# Kickstart-via-repo profile init → workflow.yaml
$kickstartViaRepoProfile = Join-Path $dotbotDir "workflows\start-from-repo"
if (Test-Path $kickstartViaRepoProfile) {
    $testProjectRepo = New-TestProject
    try {
        Push-Location $testProjectRepo
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow start-from-repo 2>&1 | Out-Null
        Pop-Location

        $botDirRepo = Join-Path $testProjectRepo ".bot"

        # Root workflow.yaml must still be the default manifest
        $rootWorkflowYaml = Join-Path $botDirRepo "workflow.yaml"
        Assert-PathExists -Name "Repo init: root workflow.yaml exists" -Path $rootWorkflowYaml
        if (Test-Path $rootWorkflowYaml) {
            $rootRaw = Get-Content $rootWorkflowYaml -Raw
            Assert-True -Name "Repo init: root workflow.yaml is default (has 'name: default')" `
                -Condition ($rootRaw -match 'name:\s*default') `
                -Message "Root workflow.yaml was overwritten by installed workflow"
        }

        # Installed workflow must be in workflows/<name>/ with its own manifest
        $installedWfYaml = Join-Path $botDirRepo "workflows\start-from-repo\workflow.yaml"
        Assert-PathExists -Name "Repo init: installed workflow.yaml in workflows/start-from-repo/" -Path $installedWfYaml
        if (Test-Path $installedWfYaml) {
            $wfRaw = Get-Content $installedWfYaml -Raw
            Assert-True -Name "Repo init: installed manifest has requires" `
                -Condition ($wfRaw -match 'requires:') -Message "No requires key found"
            Assert-True -Name "Repo init: installed manifest has domain" `
                -Condition ($wfRaw -match 'domain:') -Message "No domain key found"
        }

        # Verify recipe files were copied
        $recipesDir = Join-Path $botDirRepo "recipes\prompts"
        Assert-PathExists -Name "Repo init: 00-scan-repo-structure.md copied" -Path (Join-Path $recipesDir "00-scan-repo-structure.md")
        Assert-PathExists -Name "Repo init: 01-analyse-git-history.md copied" -Path (Join-Path $recipesDir "01-analyse-git-history.md")
        Assert-PathExists -Name "Repo init: 03b-expand-task-group.md copied" -Path (Join-Path $recipesDir "03b-expand-task-group.md")
    } finally {
        Remove-TestProject -Path $testProjectRepo
    }
} else {
    Write-TestResult -Name "Repo init workflow.yaml tests" -Status Skip -Message "start-from-repo profile not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GET-ACTIVEWORKFLOWMANIFEST RESOLUTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GET-ACTIVEWORKFLOWMANIFEST" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$manifestProj = New-TestProjectFromGolden -Flavor 'default'
$testProjectManifest = $manifestProj.ProjectRoot
try {
    $botDirManifest = $manifestProj.BotDir

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

$modesProj = New-TestProjectFromGolden -Flavor 'default'
$testProjectModes = $modesProj.ProjectRoot
try {
    $botDirModes = $modesProj.BotDir

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
    $preflightProj = New-TestProjectFromGolden -Flavor 'start-from-jira'
    $testProjectPreflight = $preflightProj.ProjectRoot
    try {
        $botDirPreflight = $preflightProj.BotDir

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
    Write-TestResult -Name "Manifest preflight tests" -Status Skip -Message "start-from-jira profile not found"
}

# Default profile should have empty/minimal preflight
$defaultPreflightProj = New-TestProjectFromGolden -Flavor 'default'
$testProjectDefaultPreflight = $defaultPreflightProj.ProjectRoot
try {
    $botDirDefaultPreflight = $defaultPreflightProj.BotDir
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

$phasesProj = New-TestProjectFromGolden -Flavor 'default'
$testProjectPhases = $phasesProj.ProjectRoot
try {
    $botDirPhases = $phasesProj.BotDir
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

$conditionsProj = New-TestProjectFromGolden -Flavor 'default'
$testProjectConditions = $conditionsProj.ProjectRoot
try {
    $botDirCond = $conditionsProj.BotDir
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
                Assert-True -Name "Task '$($task.name)' condition returns boolean result" `
                    -Condition ($condResult -is [bool]) `
                    -Message "Expected boolean but got: $($condResult)"
                Assert-True -Name "Task '$($task.name)' condition evaluates to true after init" `
                    -Condition ($condResult -eq $true) `
                    -Message "Condition evaluated to false; expected true after project init"
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
# CLI WORKFLOW ADD/REMOVE DISPATCH
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CLI WORKFLOW ADD/REMOVE DISPATCH" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Regression: PowerShell unwraps @() from if/else expressions to $null,
# causing splatting to pass a $null positional arg to workflow-add.ps1.
$cliScript = Join-Path $dotbotDir "bin\dotbot.ps1"
$kickstartWf = Join-Path $dotbotDir "workflows\start-from-prompt"
if ((Test-Path $cliScript) -and (Test-Path $kickstartWf)) {
    $cliProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectCli = $cliProj.ProjectRoot
    try {
        # Test: workflow add with no extra args (the failing scenario)
        $addOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectCli'; & '$cliScript' workflow add start-from-prompt" 2>&1
        $addFailed = $addOutput | Where-Object { $_ -match 'positional parameter cannot be found' -or $_ -match 'cannot be found that accepts argument' }
        Assert-True -Name "CLI 'workflow add' dispatches without splatting error" `
            -Condition ($null -eq $addFailed -or $addFailed.Count -eq 0) `
            -Message "Splatting empty @wfExtra passed null: $addFailed"

        $installedDir = Join-Path $testProjectCli ".bot\workflows\start-from-prompt"
        Assert-PathExists -Name "CLI 'workflow add' installs workflow directory" -Path $installedDir

        # Test: workflow remove also dispatches cleanly
        $removeOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectCli'; & '$cliScript' workflow remove start-from-prompt" 2>&1
        $removeFailed = $removeOutput | Where-Object { $_ -match 'positional parameter cannot be found' -or $_ -match 'cannot be found that accepts argument' }
        Assert-True -Name "CLI 'workflow remove' dispatches without splatting error" `
            -Condition ($null -eq $removeFailed -or $removeFailed.Count -eq 0) `
            -Message "Splatting empty @wfExtra passed null: $removeFailed"

        Assert-PathNotExists -Name "CLI 'workflow remove' removes workflow directory" -Path $installedDir

        # Test: workflow list dispatches cleanly
        $listOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectCli'; & '$cliScript' workflow list" 2>&1
        $listFailed = $listOutput | Where-Object { $_ -match 'positional parameter cannot be found' -or $_ -match 'cannot be found that accepts argument' }
        Assert-True -Name "CLI 'workflow list' dispatches without splatting error" `
            -Condition ($null -eq $listFailed -or $listFailed.Count -eq 0) `
            -Message "Splatting empty @wfExtra passed null: $listFailed"
    } finally {
        Remove-TestProject -Path $testProjectCli
    }
} else {
    Write-TestResult -Name "CLI workflow dispatch tests" -Status Skip -Message "dotbot CLI or start-from-prompt workflow not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW ADD FUNCTIONALITY
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKFLOW ADD FUNCTIONALITY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$wfAddScript = Join-Path $dotbotDir "scripts\workflow-add.ps1"
$wfRemoveScript = Join-Path $dotbotDir "scripts\workflow-remove.ps1"
$kickstartFromScratchDir = Join-Path $dotbotDir "workflows\start-from-prompt"

if ((Test-Path $wfAddScript) -and (Test-Path $kickstartFromScratchDir)) {
    # --- Test: basic add creates expected directory structure ---
    $addProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectAdd = $addProj.ProjectRoot
    try {
        $botDir = $addProj.BotDir
        $wfTarget = Join-Path $botDir "workflows\start-from-prompt"

        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectAdd'; & '$wfAddScript' start-from-prompt" 2>&1 | Out-Null

        Assert-PathExists -Name "workflow add: creates workflow directory" -Path $wfTarget
        Assert-PathExists -Name "workflow add: copies workflow.yaml" -Path (Join-Path $wfTarget "workflow.yaml")

        # Verify workflow.yaml content has expected name
        $wfYaml = Get-Content (Join-Path $wfTarget "workflow.yaml") -Raw
        Assert-True -Name "workflow add: workflow.yaml has correct name" `
            -Condition ($wfYaml -match 'name:\s*start-from-prompt') `
            -Message "workflow.yaml name mismatch"

        # Verify settings updated with installed_workflows
        $settingsPath = Join-Path $botDir "settings\settings.default.json"
        if (Test-Path $settingsPath) {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $hasWf = $settings.PSObject.Properties['installed_workflows'] -and
                     ('start-from-prompt' -in @($settings.installed_workflows))
            Assert-True -Name "workflow add: settings.installed_workflows updated" `
                -Condition $hasWf `
                -Message "start-from-prompt not in installed_workflows"
        } else {
            Write-TestResult -Name "workflow add: settings.installed_workflows updated" -Status Skip -Message "settings.default.json not found after init"
        }

        # Verify excluded files are not copied
        $onInstall = Join-Path $wfTarget "on-install.ps1"
        $manifestYaml = Join-Path $wfTarget "manifest.yaml"
        Assert-PathNotExists -Name "workflow add: on-install.ps1 excluded" -Path $onInstall
        Assert-PathNotExists -Name "workflow add: manifest.yaml excluded" -Path $manifestYaml

    } finally {
        Remove-TestProject -Path $testProjectAdd
    }

    # --- Test: duplicate add without --Force is rejected ---
    $dupProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectDup = $dupProj.ProjectRoot
    try {
        # First add
        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectDup'; & '$wfAddScript' start-from-prompt" 2>&1 | Out-Null

        # Second add without --Force should warn
        $dupOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectDup'; & '$wfAddScript' start-from-prompt" 2>&1
        $dupWarning = $dupOutput | Where-Object { $_ -match 'already installed' }
        Assert-True -Name "workflow add: duplicate without --Force is rejected" `
            -Condition ($null -ne $dupWarning -and $dupWarning.Count -gt 0) `
            -Message "Expected 'already installed' warning"

    } finally {
        Remove-TestProject -Path $testProjectDup
    }

    # --- Test: duplicate add with --Force succeeds ---
    $forceProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectForce = $forceProj.ProjectRoot
    try {
        # First add
        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectForce'; & '$wfAddScript' start-from-prompt" 2>&1 | Out-Null

        # Second add with --Force should succeed
        $forceOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectForce'; & '$wfAddScript' start-from-prompt -Force" 2>&1
        $forceSuccess = $forceOutput | Where-Object { $_ -match 'installed' -and $_ -notmatch 'already' }
        Assert-True -Name "workflow add: --Force overwrites existing workflow" `
            -Condition ($null -ne $forceSuccess -and $forceSuccess.Count -gt 0) `
            -Message "Expected success message after --Force reinstall"

        # Verify directory still exists after force reinstall
        $wfTargetForce = Join-Path $testProjectForce ".bot\workflows\start-from-prompt"
        Assert-PathExists -Name "workflow add: workflow directory exists after --Force" -Path $wfTargetForce

    } finally {
        Remove-TestProject -Path $testProjectForce
    }

    # --- Test: adding non-existent workflow fails ---
    $badProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectBad = $badProj.ProjectRoot
    try {
        $badOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectBad'; & '$wfAddScript' nonexistent-workflow-xyz" 2>&1
        $notFound = $badOutput | Where-Object { $_ -match 'not found' }
        Assert-True -Name "workflow add: non-existent workflow fails with error" `
            -Condition ($null -ne $notFound -and $notFound.Count -gt 0) `
            -Message "Expected 'not found' error for invalid workflow name"

        $badDir = Join-Path $testProjectBad ".bot\workflows\nonexistent-workflow-xyz"
        Assert-PathNotExists -Name "workflow add: no directory created for invalid workflow" -Path $badDir

    } finally {
        Remove-TestProject -Path $testProjectBad
    }

    # --- Test: task_categories merged from workflow manifest ---
    $jiraWfDir = Join-Path $dotbotDir "workflows\start-from-jira"
    if (Test-Path $jiraWfDir) {
        $catsProj = New-TestProjectFromGolden -Flavor 'default'
        $testProjectCats = $catsProj.ProjectRoot
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectCats'; & '$wfAddScript' start-from-jira" 2>&1 | Out-Null

            $settingsPath = Join-Path $testProjectCats ".bot\settings\settings.default.json"
            if (Test-Path $settingsPath) {
                $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
                $cats = @()
                if ($settings.PSObject.Properties['task_categories']) { $cats = @($settings.task_categories) }
                Assert-True -Name "workflow add: task_categories merged from manifest" `
                    -Condition ($cats.Count -gt 0) `
                    -Message "Expected task_categories to be populated from start-from-jira manifest"
                Assert-True -Name "workflow add: task_categories contains 'research'" `
                    -Condition ('research' -in $cats) `
                    -Message "Expected 'research' in task_categories"
            } else {
                Write-TestResult -Name "workflow add: task_categories merged from manifest" -Status Skip -Message "settings.default.json not found after init"
            }

            # Verify env.local scaffold created with required env vars
            $envLocal = Join-Path $testProjectCats ".env.local"
            if (Test-Path $envLocal) {
                $envContent = Get-Content $envLocal -Raw
                Assert-True -Name "workflow add: .env.local scaffolded with AZURE_DEVOPS_PAT" `
                    -Condition ($envContent -match 'AZURE_DEVOPS_PAT') `
                    -Message "Expected AZURE_DEVOPS_PAT in .env.local"
                Assert-True -Name "workflow add: .env.local scaffolded with ATLASSIAN_EMAIL" `
                    -Condition ($envContent -match 'ATLASSIAN_EMAIL') `
                    -Message "Expected ATLASSIAN_EMAIL in .env.local"
            } else {
                Assert-True -Name "workflow add: .env.local created for workflow with env_vars" `
                    -Condition $false -Message ".env.local was not created"
            }

        } finally {
            Remove-TestProject -Path $testProjectCats
        }
    } else {
        Write-TestResult -Name "workflow add: task_categories + env_vars tests" -Status Skip -Message "start-from-jira workflow not found"
    }

    # --- Test: add then remove round-trip ---
    $roundTripProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectRoundTrip = $roundTripProj.ProjectRoot
    try {
        $botDir = $roundTripProj.BotDir
        $wfDir = Join-Path $botDir "workflows\start-from-prompt"

        # Add
        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectRoundTrip'; & '$wfAddScript' start-from-prompt" 2>&1 | Out-Null
        Assert-PathExists -Name "workflow round-trip: directory exists after add" -Path $wfDir

        # Verify in installed_workflows
        $settingsPath = Join-Path $botDir "settings\settings.default.json"
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        Assert-True -Name "workflow round-trip: in installed_workflows after add" `
            -Condition ('start-from-prompt' -in @($settings.installed_workflows)) `
            -Message "Not found in installed_workflows"

        # Remove
        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectRoundTrip'; & '$wfRemoveScript' start-from-prompt" 2>&1 | Out-Null
        Assert-PathNotExists -Name "workflow round-trip: directory removed after remove" -Path $wfDir

        # Verify removed from installed_workflows
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $remaining = @()
        if ($settings.PSObject.Properties['installed_workflows']) { $remaining = @($settings.installed_workflows) }
        Assert-True -Name "workflow round-trip: removed from installed_workflows" `
            -Condition ('start-from-prompt' -notin $remaining) `
            -Message "Still in installed_workflows after remove"

    } finally {
        Remove-TestProject -Path $testProjectRoundTrip
    }

} else {
    Write-TestResult -Name "workflow add functionality tests" -Status Skip -Message "workflow-add.ps1 or start-from-prompt workflow not found"
}

# ═══════════════════════════════════════════════════════════════════
# DEFAULT WORKFLOW RESOLUTION
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  DEFAULT WORKFLOW RESOLUTION" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

$serverFile = Join-Path $dotbotDir "workflows\default\systems\ui\server.ps1"
if (Test-Path $serverFile) {
    $serverContent = Get-Content $serverFile -Raw

    Assert-True -Name "Workflow run endpoint has default workflow fallback" `
        -Condition ($serverContent -match 'if \(-not \(Test-Path \$wfDir\)\)' -and $serverContent -match 'Read-WorkflowManifest -WorkflowDir \$botRoot') `
        -Message "Missing default workflow fallback in /api/workflows/*/run endpoint"

    Assert-True -Name "Default fallback checks workflow.yaml at bot root" `
        -Condition ($serverContent -match 'Join-Path \$botRoot "workflow\.yaml"') `
        -Message "Fallback does not check .bot/workflow.yaml"

    Assert-True -Name "Workflow run endpoint validates workflow.yaml exists" `
        -Condition ($serverContent -match 'Test-Path \(Join-Path \$wfDir "workflow\.yaml"\)') `
        -Message "Missing workflow.yaml existence check after resolution"

    Assert-True -Name "Workflow run endpoint does not use Get-CachedManifest for default resolution" `
        -Condition (-not ($serverContent -match 'Get-CachedManifest.*workflows/\*/run')) `
        -Message "Default resolution should use inline Read-WorkflowManifest, not Get-CachedManifest"
} else {
    Write-TestResult -Name "server.ps1 exists" -Status Skip -Message "Server file not found"
}

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW RUN ENDPOINT: FORM DATA HANDLING
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  WORKFLOW RUN FORM DATA" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $serverFile) {
    Assert-True -Name "Workflow run endpoint reads request body" `
        -Condition ($serverContent -match 'System\.IO\.StreamReader.*\$request\.InputStream') `
        -Message "Endpoint does not read request body for form data"

    Assert-True -Name "Workflow run endpoint saves briefing files" `
        -Condition ($serverContent -match 'workspace\\product\\briefing') `
        -Message "Endpoint does not save briefing files"

    Assert-True -Name "Workflow run endpoint saves user prompt" `
        -Condition ($serverContent -match 'workflow-launch-prompt\.txt') `
        -Message "Endpoint does not save user prompt to workflow-launch-prompt.txt"

    Assert-True -Name "Workflow run endpoint returns 400 for malformed JSON" `
        -Condition ($serverContent -match 'Invalid JSON in request body') `
        -Message "Endpoint does not return 400 for malformed request body"

    Assert-True -Name "Briefing file upload uses safe filename sanitization" `
        -Condition ($serverContent -match 'GetInvalidFileNameChars') `
        -Message "File upload does not sanitize filenames with GetInvalidFileNameChars"

    # Regression: the /api/workflows/*/run handler previously assigned its success
    # payload to a local `$response` variable, shadowing the outer HttpListenerResponse
    # and causing the response to never be written back to the client.
    # The handler must use a distinct variable name (e.g. $runResponse) for its payload.
    $runHandlerMatch = [regex]::Match(
        $serverContent,
        "Start-ProcessLaunch -Type 'task-runner'[\s\S]{0,2000}?ConvertTo-Json",
        'Singleline'
    )
    Assert-True -Name "Workflow run handler does not shadow `$response HttpListenerResponse" `
        -Condition ($runHandlerMatch.Success -and -not ($runHandlerMatch.Value -match '\$response\s*=\s*@\{')) `
        -Message "Handler assigns to `$response, shadowing the outer HttpListenerResponse and breaking the write loop"
} else {
    Write-TestResult -Name "server.ps1 form data tests" -Status Skip -Message "Server file not found"
}

# ═══════════════════════════════════════════════════════════════════
# PENDING-TASKS RUNNER (server)
# Regression for issues #324 and #301: PR #274 removed the workflow-agnostic
# runner surface; this branch restored it. Endpoints, the synthetic
# `pending-tasks` row in /api/workflows/installed, and the explicit split
# between the `__default__` task bucket and the default workflow row must
# all stay wired.
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  PENDING-TASKS RUNNER (server)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $serverFile) {
    Assert-True -Name "/api/tasks/run-pending route exists" `
        -Condition ($serverContent -match '"/api/tasks/run-pending"\s*\{') `
        -Message "Missing /api/tasks/run-pending route handler"

    $runPendingMatch = [regex]::Match(
        $serverContent,
        '"/api/tasks/run-pending"\s*\{[\s\S]{0,3000}?break',
        'Singleline'
    )
    Assert-True -Name "/api/tasks/run-pending is POST-only" `
        -Condition ($runPendingMatch.Success -and $runPendingMatch.Value -match 'if \(\$method -eq "POST"\)' -and $runPendingMatch.Value -match '\$statusCode = 405') `
        -Message "run-pending handler missing POST guard or 405 fallback"

    Assert-True -Name "/api/tasks/run-pending launches unfiltered task-runner" `
        -Condition ($runPendingMatch.Success -and $runPendingMatch.Value -match "Start-ProcessLaunch\s+-Type\s+'task-runner'\s+-Continue\s+\`$true\s+-Description\s+\`$pendingTasksDescription\b") `
        -Message "run-pending handler does not invoke Start-ProcessLaunch with the expected unfiltered shape"

    Assert-True -Name "Pending-tasks description constant defined" `
        -Condition ($serverContent -match "\`$pendingTasksDescription\s*=\s*'Pending tasks \(unfiltered\)'") `
        -Message "server.ps1 must define `\$pendingTasksDescription so launch description stays in sync with stop matcher"

    Assert-True -Name "Pending-tasks description prefix constant defined" `
        -Condition ($serverContent -match "\`$pendingTasksDescriptionPrefix\s*=\s*'Pending tasks\*'") `
        -Message "server.ps1 must define `\$pendingTasksDescriptionPrefix so the stop matcher and the running-process detector share one prefix"

    Assert-True -Name "/api/tasks/run-pending does not pass -WorkflowName" `
        -Condition ($runPendingMatch.Success -and -not ($runPendingMatch.Value -match '-WorkflowName')) `
        -Message "run-pending handler must not filter by workflow — that defeats the purpose of the unfiltered runner"

    Assert-True -Name "/api/tasks/stop-pending route exists" `
        -Condition ($serverContent -match '"/api/tasks/stop-pending"\s*\{') `
        -Message "Missing /api/tasks/stop-pending route handler"

    $stopPendingMatch = [regex]::Match(
        $serverContent,
        '"/api/tasks/stop-pending"\s*\{[\s\S]{0,3000}?break',
        'Singleline'
    )
    Assert-True -Name "/api/tasks/stop-pending is POST-only" `
        -Condition ($stopPendingMatch.Success -and $stopPendingMatch.Value -match 'if \(\$method -eq "POST"\)' -and $stopPendingMatch.Value -match '\$statusCode = 405') `
        -Message "stop-pending handler missing POST guard or 405 fallback"

    Assert-True -Name "/api/tasks/stop-pending matches description with -like `$pendingTasksDescriptionPrefix" `
        -Condition ($stopPendingMatch.Success -and $stopPendingMatch.Value -match "-like\s+\`$pendingTasksDescriptionPrefix\b") `
        -Message "stop-pending handler does not filter task-runner processes by the shared description prefix variable"

    Assert-True -Name "/api/tasks/stop-pending writes <id>.stop sidecar" `
        -Condition ($stopPendingMatch.Success -and $stopPendingMatch.Value -match '\$\(\$proc\.id\)\.stop') `
        -Message "stop-pending handler does not write a .stop file for matched processes"

    Assert-True -Name "/api/workflows/installed emits synthetic 'pending-tasks' row" `
        -Condition ($serverContent -match "name\s*=\s*'pending-tasks'" -and $serverContent -match 'is_synthetic\s*=\s*\$true') `
        -Message "Synthetic pending-tasks row missing from /api/workflows/installed"

    Assert-True -Name "Synthetic pending-tasks row sources from __default__ bucket" `
        -Condition ($serverContent -match "\`$pendingBucket\s*=\s*if \(\`$tasksByWorkflow\.ContainsKey\('__default__'\)\)") `
        -Message "Synthetic row must read tasks from the __default__ bucket (untagged tasks)"

    Assert-True -Name "Default workflow row does not fold __default__ into its task counts" `
        -Condition ($serverContent -match "\`$defaultTasks\s*=\s*if \(\`$tasksByWorkflow\.ContainsKey\(\`$defaultName\)\)") `
        -Message "Default workflow row must source tasks from \$defaultName, not __default__ — folding caused #301"
} else {
    Write-TestResult -Name "pending-tasks runner tests" -Status Skip -Message "Server file not found"
}

# ═══════════════════════════════════════════════════════════════════
# CLI: DEFAULT WORKFLOW RESOLUTION IN workflow-run.ps1
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  CLI DEFAULT WORKFLOW RESOLUTION" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

$wfRunScript = Join-Path $dotbotDir "scripts\workflow-run.ps1"
if (Test-Path $wfRunScript) {
    $wfRunContent = Get-Content $wfRunScript -Raw

    Assert-True -Name "workflow-run.ps1 has default workflow fallback" `
        -Condition ($wfRunContent -match 'workflow\.yaml' -and $wfRunContent -match 'Read-WorkflowManifest -WorkflowDir \$BotDir') `
        -Message "CLI does not fall back to .bot/workflow.yaml for default workflow"

    Assert-True -Name "workflow-run.ps1 checks workflow.yaml existence" `
        -Condition ($wfRunContent -match 'Test-Path.*workflow\.yaml') `
        -Message "CLI does not validate workflow.yaml exists"
} else {
    Write-TestResult -Name "workflow-run.ps1 CLI tests" -Status Skip -Message "Script not found"
}


# ═══════════════════════════════════════════════════════════════════
# GLOBAL USER SETTINGS (runtime resolution)
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  GLOBAL USER SETTINGS (runtime)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

function Test-MothershipConfigResolution {
    param(
        [Parameter(Mandatory)]
        [hashtable]$TestProject
    )

    $dotBotLogModule = Join-Path $TestProject.BotDir "systems\runtime\modules\DotBotLog.psm1"
    $settingsModule  = Join-Path $TestProject.BotDir "systems\ui\modules\SettingsAPI.psm1"
    $staticRoot      = Join-Path $TestProject.BotDir "systems\ui\static"
    $logsDir         = Join-Path $TestProject.ControlDir "logs"

    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    Import-Module $dotBotLogModule -Force -DisableNameChecking | Out-Null
    if (Get-Command Initialize-DotBotLog -ErrorAction SilentlyContinue) {
        Initialize-DotBotLog -LogDir $logsDir -ControlDir $TestProject.ControlDir -ProjectRoot $TestProject.ProjectRoot -ConsoleEnabled $false | Out-Null
    }

    Import-Module $settingsModule -Force -DisableNameChecking | Out-Null
    Initialize-SettingsAPI -ControlDir $TestProject.ControlDir -BotRoot $TestProject.BotDir -StaticRoot $staticRoot

    return Get-MothershipConfig
}

$userSettingsFile    = Join-Path $dotbotDir "user-settings.json"
$userSettingsExisted = Test-Path $userSettingsFile
$userSettingsBackup  = $null
if ($userSettingsExisted) {
    $userSettingsBackup = Get-Content $userSettingsFile -Raw
}

try {
    # --- Test 1: ~/dotbot/user-settings.json supplies values when .control is absent ---
    $testProjectUserOnly = New-TestProjectFromGolden -Flavor 'default'
    try {
        @'
{
  "mothership": {
    "server_url": "https://from-user-settings.example.com"
  }
}
'@ | Set-Content $userSettingsFile

        $config = Test-MothershipConfigResolution -TestProject $testProjectUserOnly

        Assert-Equal -Name "user-settings: server_url applied when .control absent" `
            -Expected "https://from-user-settings.example.com" -Actual $config.server_url
    } finally {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProjectUserOnly.ProjectRoot
    }

    # --- Test 2: .control/settings.json overrides ~/dotbot/user-settings.json ---
    $testProjectPrecedence = New-TestProjectFromGolden -Flavor 'default'
    try {
        @'
{
  "mothership": {
    "server_url": "https://from-user-settings.example.com"
  }
}
'@ | Set-Content $userSettingsFile

        $controlSettingsFile = Join-Path $testProjectPrecedence.ControlDir "settings.json"
        @'
{
  "mothership": {
    "server_url": "https://from-control.example.com"
  }
}
'@ | Set-Content $controlSettingsFile

        $config = Test-MothershipConfigResolution -TestProject $testProjectPrecedence

        Assert-Equal -Name "user-settings: .control wins over ~/dotbot" `
            -Expected "https://from-control.example.com" -Actual $config.server_url
    } finally {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProjectPrecedence.ProjectRoot
    }

    # --- Test 3: missing ~/dotbot/user-settings.json is a silent no-op ---
    $testProjectMissing = New-TestProjectFromGolden -Flavor 'default'
    try {
        if (Test-Path $userSettingsFile) {
            Remove-Item $userSettingsFile -Force
        }

        $config = Test-MothershipConfigResolution -TestProject $testProjectMissing

        Assert-True -Name "user-settings: missing file does not error" `
            -Condition ($null -ne $config) `
            -Message "Get-MothershipConfig returned null when ~/dotbot/user-settings.json is missing"
    } finally {
        Remove-TestProject -Path $testProjectMissing.ProjectRoot
    }

    # --- Test 4: malformed ~/dotbot/user-settings.json does not break resolution ---
    $testProjectMalformed = New-TestProjectFromGolden -Flavor 'default'
    try {
        "{ this is not valid json !!!" | Set-Content $userSettingsFile

        $config = Test-MothershipConfigResolution -TestProject $testProjectMalformed

        Assert-True -Name "user-settings: malformed file does not break resolution" `
            -Condition ($null -ne $config) `
            -Message "Get-MothershipConfig returned null when ~/dotbot/user-settings.json is malformed"
    } finally {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProjectMalformed.ProjectRoot
    }

    # --- Test 5: init never writes ~/dotbot/user-settings.json into tracked settings ---
    @'
{
  "mothership": {
    "server_url": "https://should-not-be-committed.example.com",
    "api_key": "user-secret-key"
  }
}
'@ | Set-Content $userSettingsFile

    $testProjectNoLeak = Initialize-TestBotProject
    try {
        $trackedSettingsPath = Join-Path $testProjectNoLeak.BotDir "settings\settings.default.json"
        $trackedSettingsRaw  = Get-Content $trackedSettingsPath -Raw

        Assert-True -Name "user-settings: api_key never written to tracked settings" `
            -Condition (-not ($trackedSettingsRaw -match 'user-secret-key')) `
            -Message "api_key from ~/dotbot/user-settings.json leaked into .bot/settings/settings.default.json"

        Assert-True -Name "user-settings: server_url never written to tracked settings" `
            -Condition (-not ($trackedSettingsRaw -match 'should-not-be-committed')) `
            -Message "server_url from ~/dotbot/user-settings.json leaked into .bot/settings/settings.default.json"
    } finally {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProjectNoLeak.ProjectRoot
    }
} finally {
    if ($userSettingsExisted -and $null -ne $userSettingsBackup) {
        Set-Content $userSettingsFile $userSettingsBackup
    } elseif (Test-Path $userSettingsFile) {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Workflow Integration"

if (-not $allPassed) {
    exit 1
}
