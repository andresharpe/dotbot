#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Integration tests for workflow manifest features in initialized projects.
.DESCRIPTION
    Tests workflow manifest integration with init'd projects: form.modes
    condition evaluation, manifest-driven preflight checks, workflow status,
    Get-ActiveWorkflowManifest resolution, and workflow.json presence.
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

# Phase 6: DOTBOT_HOME is wired by Run-Tests.ps1 (or Test-Helpers when this
# file runs standalone) and points at the dev checkout — no install step.
$dotbotInstalled = (Test-Path (Join-Path $dotbotDir "src")) -and (Test-Path (Join-Path $dotbotDir "content"))
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail `
        -Message "DOTBOT_HOME=$dotbotDir does not look like a dotbot checkout. Run from a clone (src/ + content/ must exist)."
    Write-TestSummary -LayerName "Layer 2: Workflow Integration"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# workflow.json RESOLVABILITY AFTER INIT
# Phase 4: init no longer copies workflow content into .bot/. The
# runtime resolves workflows from <DOTBOT_HOME>/content/workflows/<X>/
# via Find-Workflow. The init-side post-conditions are:
#   - .bot/ exists with no bot-root workflow.json
#   - Find-Workflow returns the framework tier path for built-in names
# ═══════════════════════════════════════════════════════════════════

Write-Host "  workflow.json RESOLVABILITY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Import-Module (Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

$startFromJiraProfile = Join-Path $dotbotDir "content/workflows/start-from-jira"

foreach ($wfTest in @(
    @{ Name = 'start-from-prompt'; InitArgs = @();                                 Label = 'Default init' }
    @{ Name = 'start-from-jira';   InitArgs = @('-Workflow', 'start-from-jira'); Label = 'Jira init'    }
    @{ Name = 'start-from-pr';     InitArgs = @('-Workflow', 'start-from-pr');   Label = 'PR init'      }
    @{ Name = 'start-from-repo';   InitArgs = @('-Workflow', 'start-from-repo'); Label = 'Repo init'    }
)) {
    $sourceDir = Join-Path $dotbotDir "content/workflows/$($wfTest.Name)"
    if (-not (Test-Path $sourceDir)) {
        Write-TestResult -Name "$($wfTest.Label) workflow.json tests" -Status Skip -Message "$($wfTest.Name) source not found"
        continue
    }

    $testProject = New-TestProject
    try {
        Push-Location $testProject
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "src/cli/init-project.ps1") @($wfTest.InitArgs) 2>&1 | Out-Null
        Pop-Location

        $botDirTest = Join-Path $testProject ".bot"

        Assert-PathNotExists -Name "$($wfTest.Label): no .bot/workflow.json at bot root" `
            -Path (Join-Path $botDirTest "workflow.json")

        $resolved = Find-Workflow -BotRoot $botDirTest -Name $wfTest.Name
        Assert-True -Name "$($wfTest.Label): Find-Workflow resolves $($wfTest.Name)" `
            -Condition ($resolved.ok -eq $true) `
            -Message "Find-Workflow failed: $($resolved.message)"

        if ($resolved.ok) {
            $resolvedJSON = Join-Path $resolved.path "workflow.json"
            Assert-PathExists -Name "$($wfTest.Label): resolved workflow.json exists" -Path $resolvedJSON
            if (Test-Path $resolvedJSON) {
                $raw = Get-Content $resolvedJSON -Raw
                if ($wfTest.Name -eq 'start-from-prompt') {
                    Assert-True -Name "$($wfTest.Label): workflow.json has tasks" `
                        -Condition ($raw -match '"tasks"\s*:') -Message "No tasks key found"
                    Assert-True -Name "$($wfTest.Label): workflow.json has form" `
                        -Condition ($raw -match '"form"\s*:') -Message "No form key found"
                } else {
                    Assert-True -Name "$($wfTest.Label): manifest has requires" `
                        -Condition ($raw -match '"requires"\s*:') -Message "No requires key found"
                    Assert-True -Name "$($wfTest.Label): manifest has domain" `
                        -Condition ($raw -match '"domain"\s*:') -Message "No domain key found"
                }
            }
        }
    } finally {
        Remove-TestProject -Path $testProject
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GET-ACTIVEWORKFLOWMANIFEST RESOLUTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GET-ACTIVEWORKFLOWMANIFEST" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$manifestProj = New-TestProjectFromGolden -Flavor 'start-from-prompt'
$testProjectManifest = $manifestProj.ProjectRoot
try {
    $botDirManifest = $manifestProj.BotDir

    # Dot-source the workflow manifest module from the installed bot
    Import-Module (Join-Path $botDirManifest "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

    # Resolution from the installed workflow at .bot/content/workflows/start-from-prompt/
    $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirManifest
    Assert-True -Name "Get-ActiveWorkflowManifest finds manifest" `
        -Condition ($null -ne $manifest) -Message "Manifest not found"

    if ($manifest) {
        Assert-Equal -Name "Resolved manifest name is 'start-from-prompt'" `
            -Expected "start-from-prompt" -Actual $manifest.name
        Assert-True -Name "Resolved manifest has tasks" `
            -Condition ($manifest.tasks -and $manifest.tasks.Count -gt 0) -Message "No tasks"
        Assert-True -Name "Resolved manifest has form" `
            -Condition ($null -ne $manifest.form) -Message "No form"
    }

    # No manifest → returns null. Point DOTBOT_HOME at the same empty dir so
    # the framework tier resolves to nothing — otherwise the installed
    # dotbot's framework workflows would surface as the alphabetic-first
    # fallback and the assertion would fail.
    $noManifestDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-nomanifest-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Path $noManifestDir -Force | Out-Null
    $savedDotbotHomeNoManifest = $env:DOTBOT_HOME
    try {
        $env:DOTBOT_HOME = Join-Path $noManifestDir "no-framework"
        $nullResult = Get-ActiveWorkflowManifest -BotRoot $noManifestDir
        Assert-True -Name "No manifest returns null" `
            -Condition ($null -eq $nullResult) -Message "Expected null"
    } finally {
        if ($null -ne $savedDotbotHomeNoManifest -and $savedDotbotHomeNoManifest -ne '') {
            $env:DOTBOT_HOME = $savedDotbotHomeNoManifest
        } elseif (Test-Path Env:DOTBOT_HOME) {
            Remove-Item Env:DOTBOT_HOME
        }
        Remove-Item -Path $noManifestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # settings.workflow takes precedence over alphabetic-first.
    # Override settings.workflow to point at a fresh test-workflow we install
    # on top of the golden's start-from-prompt.
    $wfDir = Join-Path $botDirManifest "content" "workflows" "test-workflow"
    New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
    @'
{
  "name": "test-workflow",
  "version": "1.0",
  "description": "A test workflow",
  "min_dotbot_version": "3.5",
  "tasks": [
    {
      "name": "Test Task",
      "type": "prompt",
      "priority": 1
    }
  ]
}
'@ | Set-Content (Join-Path $wfDir "workflow.json")

    # Phase 4: project-tier settings overrides live in .control/settings.json
    # (the highest precedence layer Get-MergedSettings reads).
    $controlSettingsPath = Join-Path $botDirManifest ".control" "settings.json"
    $controlDir = Split-Path -Parent $controlSettingsPath
    if (-not (Test-Path $controlDir)) { New-Item -ItemType Directory -Path $controlDir -Force | Out-Null }
    $controlSettings = [pscustomobject]@{}
    if (Test-Path $controlSettingsPath) {
        try { $controlSettings = Get-Content $controlSettingsPath -Raw | ConvertFrom-Json } catch {}
    }
    $controlSettings | Add-Member -NotePropertyName "workflow" -NotePropertyValue "test-workflow" -Force
    $controlSettings | ConvertTo-Json -Depth 10 | Set-Content $controlSettingsPath

    $installedManifest = Get-ActiveWorkflowManifest -BotRoot $botDirManifest
    Assert-True -Name "settings.workflow selects the active workflow" `
        -Condition ($installedManifest.name -eq "test-workflow") `
        -Message "Expected 'test-workflow', got '$($installedManifest.name)'"

    # Clean up so later tests start from the unmodified golden.
    Remove-Item -Path (Join-Path $botDirManifest "content" "workflows" "test-workflow") -Recurse -Force -ErrorAction SilentlyContinue

} finally {
    Remove-TestProject -Path $testProjectManifest
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# FORM.MODES CONDITION EVALUATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FORM.MODES CONDITIONS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$modesProj = New-TestProjectFromGolden -Flavor 'start-from-prompt'
$testProjectModes = $modesProj.ProjectRoot
try {
    $botDirModes = $modesProj.BotDir

    # Dot-source workflow manifest module
    Import-Module (Join-Path $botDirModes "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

    $manifest = Get-ActiveWorkflowManifest -BotRoot $botDirModes
    if (-not $manifest -or -not $manifest.form -or -not $manifest.form.modes) {
        Write-TestResult -Name "form.modes tests" -Status Skip -Message "No form.modes in manifest"
    } else {
        $modes = $manifest.form.modes

        # start-from-prompt has 2 modes based on mission.md:
        #   new_project: condition !.bot/workspace/product/mission.md
        #   has_docs:    condition .bot/workspace/product/mission.md

        # State 1: Fresh project — no mission.md → new_project mode
        $matchedMode = $null
        foreach ($mode in $modes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $testProjectModes -Condition $modeCondition) {
                $matchedMode = if ($mode -is [System.Collections.IDictionary]) { $mode['id'] } else { $mode.id }
                break
            }
        }
        Assert-Equal -Name "Fresh project without mission.md matches new_project mode" `
            -Expected "new_project" -Actual $matchedMode

        # State 2: Create mission.md → has_docs should match
        $productDir = Join-Path $botDirModes "workspace\product"
        if (-not (Test-Path $productDir)) { New-Item -ItemType Directory -Path $productDir -Force | Out-Null }
        "# Mission" | Set-Content (Join-Path $productDir "mission.md")

        $matchedMode2 = $null
        foreach ($mode in $modes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $testProjectModes -Condition $modeCondition) {
                $matchedMode2 = if ($mode -is [System.Collections.IDictionary]) { $mode['id'] } else { $mode.id }
                break
            }
        }
        Assert-Equal -Name "Project with mission.md matches has_docs mode" `
            -Expected "has_docs" -Actual $matchedMode2

        # State 3: Remove mission.md again → back to new_project
        Remove-Item (Join-Path $productDir "mission.md") -Force

        $matchedMode3 = $null
        foreach ($mode in $modes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $testProjectModes -Condition $modeCondition) {
                $matchedMode3 = if ($mode -is [System.Collections.IDictionary]) { $mode['id'] } else { $mode.id }
                break
            }
        }
        Assert-Equal -Name "After removing mission.md matches new_project mode" `
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

if (Test-Path $startFromJiraProfile) {
    $preflightProj = New-TestProjectFromGolden -Flavor 'start-from-jira'
    $testProjectPreflight = $preflightProj.ProjectRoot
    try {
        $botDirPreflight = $preflightProj.BotDir

        # Dot-source modules
        Import-Module (Join-Path $botDirPreflight "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

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
    Import-Module (Join-Path $botDirDefaultPreflight "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

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
    Import-Module (Join-Path $botDirPhases "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

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
    Import-Module (Join-Path $botDirCond "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

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
$startFromPromptWf = Join-Path $dotbotDir "content" "workflows" "start-from-prompt"
if ((Test-Path $cliScript) -and (Test-Path $startFromPromptWf)) {
    $cliProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectCli = $cliProj.ProjectRoot
    try {
        # Test: workflow add with no extra args (the failing scenario)
        $addOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectCli'; & '$cliScript' workflow add start-from-prompt" 2>&1
        $addFailed = $addOutput | Where-Object { $_ -match 'positional parameter cannot be found' -or $_ -match 'cannot be found that accepts argument' }
        Assert-True -Name "CLI 'workflow add' dispatches without splatting error" `
            -Condition ($null -eq $addFailed -or $addFailed.Count -eq 0) `
            -Message "Splatting empty @wfExtra passed null: $addFailed"

        # Phase 4: workflow add records the selection in .control/settings.json
        # rather than installing a project tier directory (start-from-prompt
        # ships no overrides/ subtree).
        $cliControlSettings = Join-Path $testProjectCli ".bot/.control/settings.json"
        Assert-PathExists -Name "CLI 'workflow add' writes .control/settings.json" -Path $cliControlSettings
        if (Test-Path $cliControlSettings) {
            $cliSettings = Get-Content $cliControlSettings -Raw | ConvertFrom-Json
            Assert-Equal -Name "CLI 'workflow add' records workflow selection" `
                -Expected "start-from-prompt" -Actual $cliSettings.workflow
        }

        # Test: workflow remove also dispatches cleanly
        $removeOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectCli'; & '$cliScript' workflow remove start-from-prompt" 2>&1
        $removeFailed = $removeOutput | Where-Object { $_ -match 'positional parameter cannot be found' -or $_ -match 'cannot be found that accepts argument' }
        Assert-True -Name "CLI 'workflow remove' dispatches without splatting error" `
            -Condition ($null -eq $removeFailed -or $removeFailed.Count -eq 0) `
            -Message "Splatting empty @wfExtra passed null: $removeFailed"

        if (Test-Path $cliControlSettings) {
            $afterRemove = Get-Content $cliControlSettings -Raw | ConvertFrom-Json
            Assert-True -Name "CLI 'workflow remove' clears selection" `
                -Condition (-not $afterRemove.PSObject.Properties['workflow']) `
                -Message "Workflow key still present after remove"
        }

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
# WORKFLOW ADD FUNCTIONALITY (Phase 4)
# Workflow content lives in <DOTBOT_HOME>/content/workflows/. `workflow add X`:
#   - records `workflow: X` in .bot/.control/settings.json
#   - materialises <source>/overrides/ → .bot/content/workflows/X/ only if
#     the framework workflow declares an overrides/ subtree
#   - never touches .mcp.json, .env.local, settings.default.json
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKFLOW ADD FUNCTIONALITY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$wfAddScript = Join-Path $dotbotDir "src/cli/workflow-add.ps1"
$wfRemoveScript = Join-Path $dotbotDir "src/cli/workflow-remove.ps1"
$startFromPromptDir = Join-Path $dotbotDir "content/workflows/start-from-prompt"

if ((Test-Path $wfAddScript) -and (Test-Path $startFromPromptDir)) {
    # --- Test: add records selection in .control/settings.json ---
    $addProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectAdd = $addProj.ProjectRoot
    try {
        $botDir = $addProj.BotDir
        $controlSettings = Join-Path $botDir ".control/settings.json"

        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectAdd'; & '$wfAddScript' start-from-prompt" 2>&1 | Out-Null

        Assert-PathExists -Name "workflow add: .control/settings.json updated" -Path $controlSettings
        if (Test-Path $controlSettings) {
            $settings = Get-Content $controlSettings -Raw | ConvertFrom-Json
            Assert-Equal -Name "workflow add: settings.workflow == 'start-from-prompt'" `
                -Expected "start-from-prompt" -Actual $settings.workflow
        }

        # start-from-prompt ships no overrides/ subtree, so no project tier
        # directory should be created.
        $wfTarget = Join-Path $botDir "content/workflows/start-from-prompt"
        Assert-PathNotExists -Name "workflow add: no project tier directory when source has no overrides/" -Path $wfTarget

        # Framework content (manifest.json, on-install.ps1) is never copied
        # into .bot/.
        Assert-PathNotExists -Name "workflow add: manifest.json not copied" -Path (Join-Path $wfTarget "manifest.json")
        Assert-PathNotExists -Name "workflow add: on-install.ps1 not copied" -Path (Join-Path $wfTarget "on-install.ps1")
    } finally {
        Remove-TestProject -Path $testProjectAdd
    }

    # --- Test: add with overrides creates project tier directory ---
    $ovrProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectOvr = $ovrProj.ProjectRoot
    $ovrFakeHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-wfadd-home-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $ovrPrevHome = $env:DOTBOT_HOME
    try {
        # Build a fake DOTBOT_HOME with an overrides-shipping workflow.
        New-Item -ItemType Directory -Path (Join-Path $ovrFakeHome "bin") -Force | Out-Null
        New-Item -ItemType File      -Path (Join-Path $ovrFakeHome "bin/dotbot.ps1") -Force | Out-Null
        Copy-Item (Join-Path $dotbotDir "src")     -Destination (Join-Path $ovrFakeHome "src")     -Recurse -Force
        Copy-Item (Join-Path $dotbotDir "content") -Destination (Join-Path $ovrFakeHome "content") -Recurse -Force
        $fakeWfDir = Join-Path $ovrFakeHome "content/workflows/has-overrides"
        New-Item -ItemType Directory -Path (Join-Path $fakeWfDir "overrides/recipes/prompts") -Force | Out-Null
        '{"name":"has-overrides","description":"test fixture"}' | Set-Content (Join-Path $fakeWfDir "workflow.json")
        "override content" | Set-Content (Join-Path $fakeWfDir "overrides/recipes/prompts/00-test.md")

        $env:DOTBOT_HOME = $ovrFakeHome
        $fakeWfAddScript = Join-Path $ovrFakeHome "src/cli/workflow-add.ps1"

        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectOvr'; & '$fakeWfAddScript' has-overrides" 2>&1 | Out-Null

        $ovrBot = $ovrProj.BotDir
        Assert-PathExists -Name "workflow add overrides: project tier dir created" `
            -Path (Join-Path $ovrBot "content/workflows/has-overrides")
        Assert-PathExists -Name "workflow add overrides: override file copied" `
            -Path (Join-Path $ovrBot "content/workflows/has-overrides/recipes/prompts/00-test.md")
    } finally {
        if ($null -ne $ovrPrevHome -and $ovrPrevHome -ne '') {
            $env:DOTBOT_HOME = $ovrPrevHome
        } elseif (Test-Path Env:DOTBOT_HOME) {
            Remove-Item Env:DOTBOT_HOME
        }
        Remove-TestProject -Path $testProjectOvr
        Remove-Item $ovrFakeHome -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Test: non-existent workflow fails ---
    $badProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectBad = $badProj.ProjectRoot
    try {
        $badOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectBad'; & '$wfAddScript' nonexistent-workflow-xyz" 2>&1
        $notFound = $badOutput | Where-Object { $_ -match 'not found' }
        Assert-True -Name "workflow add: non-existent workflow fails with error" `
            -Condition ($null -ne $notFound -and $notFound.Count -gt 0) `
            -Message "Expected 'not found' error for invalid workflow name"
    } finally {
        Remove-TestProject -Path $testProjectBad
    }

    # --- Test: add then remove round-trip ---
    $roundTripProj = New-TestProjectFromGolden -Flavor 'default'
    $testProjectRoundTrip = $roundTripProj.ProjectRoot
    try {
        $botDir = $roundTripProj.BotDir
        $controlSettings = Join-Path $botDir ".control/settings.json"

        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectRoundTrip'; & '$wfAddScript' start-from-prompt" 2>&1 | Out-Null
        $afterAdd = Get-Content $controlSettings -Raw | ConvertFrom-Json
        Assert-Equal -Name "workflow round-trip: workflow recorded after add" `
            -Expected "start-from-prompt" -Actual $afterAdd.workflow

        & pwsh -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '$testProjectRoundTrip'; & '$wfRemoveScript' start-from-prompt" 2>&1 | Out-Null
        $afterRemove = Get-Content $controlSettings -Raw | ConvertFrom-Json
        Assert-True -Name "workflow round-trip: workflow cleared after remove" `
            -Condition (-not $afterRemove.PSObject.Properties['workflow']) `
            -Message "Workflow key still present after remove: $($afterRemove.workflow)"
    } finally {
        Remove-TestProject -Path $testProjectRoundTrip
    }

} else {
    Write-TestResult -Name "workflow add functionality tests" -Status Skip -Message "workflow-add.ps1 or start-from-prompt workflow not found"
}

# ═══════════════════════════════════════════════════════════════════
# DEFAULT WORKFLOW RESOLUTION
# ═══════════════════════════════════════════════════════════════════

$serverFile = Join-Path $dotbotDir "src/ui/server.ps1"
if (Test-Path $serverFile) {
    $serverContent = Get-Content $serverFile -Raw
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

    $processLaunchMatch = [regex]::Match(
        $serverContent,
        '"/api/process/launch"\s*\{[\s\S]{0,2500}?Start-ProcessLaunch[\s\S]{0,500}?ConvertTo-Json',
        'Singleline'
    )
    Assert-True -Name "/api/process/launch forwards run_id to Start-ProcessLaunch" `
        -Condition ($processLaunchMatch.Success -and $processLaunchMatch.Value -match '\$bRunId\s*=\s*if \(\$body\.PSObject\.Properties\[''run_id''\]\)' -and $processLaunchMatch.Value -match '-RunId\s+\$bRunId') `
        -Message "Generic process launch must preserve run_id for run-scoped workflow task-runners"

    Assert-True -Name "Workflow process matcher helper exists" `
        -Condition ($serverContent -match 'function\s+Test-WorkflowProcessMatchesName\b') `
        -Message "server.ps1 should centralize workflow process identity matching"

    $workflowMatcherMatch = [regex]::Match(
        $serverContent,
        'function\s+Test-WorkflowProcessMatchesName\b[\s\S]{0,1200}?^}',
        'Multiline'
    )
    Assert-True -Name "Workflow process matcher prefers exact workflow_name" `
        -Condition ($workflowMatcherMatch.Success -and $workflowMatcherMatch.Value -match 'workflow_name' -and $workflowMatcherMatch.Value -match '-eq\s+\$WorkflowName') `
        -Message "Workflow process matching must use exact workflow_name when process files carry it"

    Assert-True -Name "Workflow process matcher keeps legacy description fallback" `
        -Condition ($workflowMatcherMatch.Success -and $workflowMatcherMatch.Value -match 'description' -and $workflowMatcherMatch.Value -match '-like\s+"\*\$WorkflowName\*"') `
        -Message "Old process files without workflow_name should still be stoppable/detectable by description"
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

    $installedWorkflowMatch = [regex]::Match(
        $serverContent,
        '"/api/workflows/installed"\s*\{[\s\S]{0,8000}?\$installedList\s*\+=',
        'Singleline'
    )
    Assert-True -Name "/api/workflows/installed matches workflow processes by helper" `
        -Condition ($installedWorkflowMatch.Success -and $installedWorkflowMatch.Value -match 'Test-WorkflowProcessMatchesName\s+-Process\s+\$_\s+-WorkflowName\s+\$wfName') `
        -Message "Installed workflow status must not infer running state from a raw description substring"

    $stopWorkflowMatch = [regex]::Match(
        $serverContent,
        '\{ \$_ -like "/api/workflows/\*/stop" \}\s*\{[\s\S]{0,3000}?break',
        'Singleline'
    )
    Assert-True -Name "/api/workflows/{name}/stop matches workflow processes by helper" `
        -Condition ($stopWorkflowMatch.Success -and $stopWorkflowMatch.Value -match 'Test-WorkflowProcessMatchesName\s+-Process\s+\$proc\s+-WorkflowName\s+\$wfName') `
        -Message "Workflow stop must not infer target process from a raw description substring"

    Assert-True -Name "/api/workflows/installed emits synthetic 'pending-tasks' row" `
        -Condition ($serverContent -match "name\s*=\s*'pending-tasks'" -and $serverContent -match 'is_synthetic\s*=\s*\$true') `
        -Message "Synthetic pending-tasks row missing from /api/workflows/installed"

    Assert-True -Name "Synthetic pending-tasks row sources from __default__ bucket" `
        -Condition ($serverContent -match "\`$pendingBucket\s*=\s*if \(\`$tasksByWorkflow\.ContainsKey\('__default__'\)\)") `
        -Message "Synthetic row must read tasks from the __default__ bucket (untagged tasks)"

    # PR-5: the synthetic 'default' workflow row was removed when workflows/default
    # was deleted. /api/workflows/installed must not emit a default entry.
    Assert-True -Name "/api/workflows/installed does not emit synthetic 'default' row" `
        -Condition (-not ($serverContent -match 'is_default\s*=\s*\$true')) `
        -Message "Synthetic 'default' row should be gone after PR-5"

    # Subfolders without workflow.json must be skipped, not indexed into.
    $installedLoopMatch = [regex]::Match(
        $serverContent,
        'Get-CachedManifest\s+-Dir\s+\$wfDir[\s\S]{0,2000}?\$installedList\s*\+=',
        'Singleline'
    )
    Assert-True -Name "/api/workflows/installed skips folders with no workflow.json" `
        -Condition ($installedLoopMatch.Success -and $installedLoopMatch.Value -match 'if\s*\(\s*-not\s+\$manifest\s*\)') `
        -Message "Enumeration loop must guard against `$null manifest before indexing properties"

    # Empty/whitespace-only workflow.json must be treated the same as missing.
    $cachedManifestMatch = [regex]::Match(
        $serverContent,
        'function\s+Get-CachedManifest\b[\s\S]{0,2000}?function\s+Get-CachedTaskWorkflow\b',
        'Singleline'
    )
    Assert-True -Name "Get-CachedManifest gates on Test-ValidWorkflowDir" `
        -Condition ($cachedManifestMatch.Success -and $cachedManifestMatch.Value -match 'Test-ValidWorkflowDir') `
        -Message "Get-CachedManifest must delegate to Test-ValidWorkflowDir so missing/empty JSON is treated as `$null"

    # /api/workflows/{name}/form and /run must reject empty/missing workflow.json,
    # not just absent files. route validation may go through
    # Find-Workflow (which internally calls Test-ValidWorkflowDir), or via a
    # direct Test-ValidWorkflowDir call.
    $formRouteMatch = [regex]::Match(
        $serverContent,
        '"\/api\/workflows\/\*\/form"[\s\S]{0,2500}?Read-WorkflowManifest',
        'Singleline'
    )
    Assert-True -Name "/api/workflows/{name}/form gates on Test-ValidWorkflowDir" `
        -Condition ($formRouteMatch.Success -and ($formRouteMatch.Value -match 'Test-ValidWorkflowDir' -or $formRouteMatch.Value -match 'Find-Workflow')) `
        -Message "/form route must validate JSON content (directly or via Find-Workflow), not just file presence"

    $runRouteMatch = [regex]::Match(
        $serverContent,
        '"\/api\/workflows\/\*\/run"[\s\S]{0,6000}?Read-WorkflowManifest',
        'Singleline'
    )
    Assert-True -Name "/api/workflows/{name}/run gates on Test-ValidWorkflowDir" `
        -Condition ($runRouteMatch.Success -and ($runRouteMatch.Value -match 'Test-ValidWorkflowDir' -or $runRouteMatch.Value -match 'Find-Workflow')) `
        -Message "/run route must validate JSON content (directly or via Find-Workflow), not just file presence"
} else {
    Write-TestResult -Name "pending-tasks runner tests" -Status Skip -Message "Server file not found"
}

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW-MANIFEST.PS1 (active manifest fallback)
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ACTIVE WORKFLOW MANIFEST FALLBACK" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$wfManifestSrc = Get-Content (Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1") -Raw

Assert-True -Name "Test-ValidWorkflowDir defined" `
    -Condition ($wfManifestSrc -match 'function\s+Test-ValidWorkflowDir\b') `
    -Message "Test-ValidWorkflowDir must exist as the single source of truth for valid workflow folders"

$activeFnMatch = [regex]::Match(
    $wfManifestSrc,
    'function\s+Get-ActiveWorkflowManifest\b[\s\S]{0,3000}?\nfunction\s+',
    'Singleline'
)
Assert-True -Name "Get-ActiveWorkflowManifest fallback uses Test-ValidWorkflowDir" `
    -Condition ($activeFnMatch.Success -and (
        ($activeFnMatch.Value -split 'Test-ValidWorkflowDir').Length -ge 3 -or
        # Find-Workflow + Discover-Workflows both delegate to
        # Test-ValidWorkflowDir internally; either pair covers the same
        # invariant — named-path lookup AND alphabetic-first fallback.
        ($activeFnMatch.Value -match 'Find-Workflow' -and $activeFnMatch.Value -match 'Discover-Workflows')
    )) `
    -Message "Get-ActiveWorkflowManifest must apply Test-ValidWorkflowDir on both the named-workflow path and the alphabetic-first scan (directly or via Find-Workflow + Discover-Workflows)"

# ═══════════════════════════════════════════════════════════════════
# INSTALL SCRIPTS (workflow-add, init-project)
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  INSTALL SCRIPT SOURCE-JSON VALIDATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$workflowAddSrc = Get-Content (Join-Path $dotbotDir "src/cli/workflow-add.ps1") -Raw
Assert-True -Name "workflow-add.ps1 aborts when source has no usable workflow.json" `
    -Condition ($workflowAddSrc -match 'Test-ValidWorkflowDir[\s\S]{0,800}?exit\s+1') `
    -Message "workflow-add.ps1 must call Test-ValidWorkflowDir and exit 1 before registering the workflow"

# Phase 4 init no longer installs workflow content into .bot/, so it has
# no per-workflow registration loop. workflow.json validity is enforced
# at runtime by Find-Workflow / Discover-Workflows + Test-ValidWorkflowDir,
# which the next two assertions cover.

$wfListSrc = Get-Content (Join-Path $dotbotDir "src/cli/workflow-list.ps1") -Raw
# workflow-list now delegates filtering to Discover-Workflows, which
# itself gates on Test-ValidWorkflowDir.
Assert-True -Name "workflow-list.ps1 skips folders without a usable workflow.json" `
    -Condition (($wfListSrc -match 'Test-ValidWorkflowDir[\s\S]{0,200}?continue') -or `
                ($wfListSrc -match 'Discover-Workflows')) `
    -Message "workflow-list.ps1 must use Test-ValidWorkflowDir + continue, or Discover-Workflows, to skip invalid subfolders"

$wfRunSrc = Get-Content (Join-Path $dotbotDir "src/cli/workflow-run.ps1") -Raw
# workflow-run gates the run on Find-Workflow now, which exits the
# script with a not-found error when no tier has a usable manifest.
Assert-True -Name "workflow-run.ps1 rejects workflows without a usable workflow.json" `
    -Condition (($wfRunSrc -match 'Test-ValidWorkflowDir[\s\S]{0,400}?exit\s+1') -or `
                ($wfRunSrc -match 'Find-Workflow[\s\S]{0,400}?exit\s+1')) `
    -Message "workflow-run.ps1 must call Test-ValidWorkflowDir or Find-Workflow before treating the workflow as installed"
Assert-True -Name "workflow-run.ps1 has no bare Test-Path on workflow.json" `
    -Condition (-not ($wfRunSrc -match 'Test-Path[^\)\r\n]*workflow\.JSON')) `
    -Message "workflow-run.ps1 must not gate on Test-Path workflow.json; use Test-ValidWorkflowDir or Find-Workflow instead"

$registryListSrc = Get-Content (Join-Path $dotbotDir "src/cli/registry-list.ps1") -Raw
Assert-True -Name "registry-list.ps1 gates workflow description on Test-ValidWorkflowDir" `
    -Condition ($registryListSrc -match 'Test-ValidWorkflowDir') `
    -Message "registry-list.ps1 must apply the missing/empty/whitespace rule when previewing registry workflows"
Assert-True -Name "registry-list.ps1 has no bare Test-Path on workflow.json" `
    -Condition (-not ($registryListSrc -match 'Test-Path[^\)\r\n]*workflow\.JSON')) `
    -Message "registry-list.ps1 must not gate on Test-Path workflow.json; use Test-ValidWorkflowDir instead"

$mcpSrc = Get-Content (Join-Path $dotbotDir "src/mcp/dotbot-mcp.ps1") -Raw
# tool discovery walks Discover-Workflows, which gates internally.
Assert-True -Name "dotbot-mcp.ps1 gates workflow tool discovery on Test-ValidWorkflowDir" `
    -Condition (($mcpSrc -match 'Test-ValidWorkflowDir') -or ($mcpSrc -match 'Discover-Workflows')) `
    -Message "dotbot-mcp.ps1 must skip workflow subfolders that fail Test-ValidWorkflowDir (directly or via Discover-Workflows)"

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

    $dotBotLogModule = Join-Path $TestProject.BotDir "src/runtime/Modules/Dotbot.Logging/Dotbot.Logging.psd1"
    $settingsModule  = Join-Path $TestProject.BotDir "src/ui/modules/SettingsAPI.psm1"
    $staticRoot      = Join-Path $TestProject.BotDir "src/ui/static"
    $logsDir         = Join-Path $TestProject.ControlDir "logs"

    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    Import-Module $dotBotLogModule -Force -DisableNameChecking | Out-Null
    if (Get-Command Initialize-DotbotLog -ErrorAction SilentlyContinue) {
        Initialize-DotbotLog -LogDir $logsDir -ControlDir $TestProject.ControlDir -ProjectRoot $TestProject.ProjectRoot -ConsoleEnabled $false | Out-Null
    }

    Import-Module $settingsModule -Force -DisableNameChecking | Out-Null
    Initialize-SettingsAPI -ControlDir $TestProject.ControlDir -BotRoot $TestProject.BotDir -StaticRoot $staticRoot

    return Get-MothershipConfig
}

# Isolate the user-settings layer so we never touch the real machine home.
# Dotbot.Settings reads user-settings.json from Get-DotbotUserSettingsPath,
# which resolves $XDG_CONFIG_HOME on Linux/macOS and $APPDATA on Windows.
$userSettingsPreviousXdg     = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
$userSettingsPreviousAppData = [Environment]::GetEnvironmentVariable('APPDATA')
$userSettingsHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-userconfig-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $userSettingsHome -Force | Out-Null
[Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $userSettingsHome, 'Process')
[Environment]::SetEnvironmentVariable('APPDATA', $userSettingsHome, 'Process')

# Reload Dotbot.Settings so Get-DotbotUserSettingsPath sees the new env vars
# and the module's migration flag is fresh for the integration block.
$settingsLoaderModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Settings/Dotbot.Settings.psd1"
if (Test-Path $settingsLoaderModule) {
    Import-Module $settingsLoaderModule -Force -DisableNameChecking -Global
    Invoke-DotbotUserSettingsMigration -Force | Out-Null
}

$settingsCoreModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Core/Dotbot.Core.psd1"
if (Test-Path $settingsCoreModule) {
    Import-Module $settingsCoreModule -Force -DisableNameChecking -Global
}

$userSettingsFile = Get-DotbotUserSettingsPath
New-Item -ItemType Directory -Path (Split-Path -Parent $userSettingsFile) -Force | Out-Null
$userSettingsExisted = Test-Path $userSettingsFile
$userSettingsBackup  = $null
if ($userSettingsExisted) {
    $userSettingsBackup = Get-Content $userSettingsFile -Raw
}

try {
    # --- Test 1: user-settings.json supplies values when .control is absent ---
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

    # --- Test 2: .control/settings.json overrides user-settings.json ---
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

        Assert-Equal -Name "user-settings: .control wins over user-settings" `
            -Expected "https://from-control.example.com" -Actual $config.server_url
    } finally {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProjectPrecedence.ProjectRoot
    }

    # --- Test 3: missing user-settings.json is a silent no-op ---
    $testProjectMissing = New-TestProjectFromGolden -Flavor 'default'
    try {
        if (Test-Path $userSettingsFile) {
            Remove-Item $userSettingsFile -Force
        }

        $config = Test-MothershipConfigResolution -TestProject $testProjectMissing

        Assert-True -Name "user-settings: missing file does not error" `
            -Condition ($null -ne $config) `
            -Message "Get-MothershipConfig returned null when user-settings.json is missing"
    } finally {
        Remove-TestProject -Path $testProjectMissing.ProjectRoot
    }

    # --- Test 4: malformed user-settings.json does not break resolution ---
    $testProjectMalformed = New-TestProjectFromGolden -Flavor 'default'
    try {
        "{ this is not valid json !!!" | Set-Content $userSettingsFile

        $config = Test-MothershipConfigResolution -TestProject $testProjectMalformed

        Assert-True -Name "user-settings: malformed file does not break resolution" `
            -Condition ($null -ne $config) `
            -Message "Get-MothershipConfig returned null when user-settings.json is malformed"
    } finally {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProjectMalformed.ProjectRoot
    }

    # Phase 4 removed the tracked .bot/settings/settings.default.json that
    # the legacy "init never leaks user-settings" assertion read. The
    # framework default now lives at <DOTBOT_HOME>/content/settings/, which
    # init never writes to. The leak scenario is therefore structurally
    # impossible — assertion retired.
} finally {
    if ($userSettingsExisted -and $null -ne $userSettingsBackup) {
        Set-Content $userSettingsFile $userSettingsBackup
    } elseif (Test-Path $userSettingsFile) {
        Remove-Item $userSettingsFile -Force -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $userSettingsPreviousXdg, 'Process')
    [Environment]::SetEnvironmentVariable('APPDATA', $userSettingsPreviousAppData, 'Process')
    Remove-Item $userSettingsHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Workflow Integration"

if (-not $allPassed) {
    exit 1
}
