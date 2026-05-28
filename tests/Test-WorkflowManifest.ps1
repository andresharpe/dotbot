#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit tests for workflow manifest functions.
.DESCRIPTION
    Tests the WorkflowManifest.psm1 functions directly from repo source.
    Covers Test-ManifestCondition, Read-WorkflowManifest,
    Convert-ManifestRequiresToPreflightChecks, Convert-ManifestTasksToPhases,
    Ensure-ManifestTaskIds, New-WorkflowTask, Merge-McpServers,
    Clear-WorkflowTasks, New-EnvLocalScaffold.
    No installed dotbot or AI dependency required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Workflow Manifest Unit Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Dot-source the module under test
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

# ═══════════════════════════════════════════════════════════════════
# Test-ManifestCondition
# ═══════════════════════════════════════════════════════════════════

Write-Host "  Test-ManifestCondition" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Set up a temp project root with known file structure
$conditionRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-cond-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $conditionRoot -Force | Out-Null

try {
    # Create test structure
    $botDir = Join-Path $conditionRoot ".bot"
    New-Item -ItemType Directory -Path (Join-Path $botDir "workspace\product") -Force | Out-Null
    "# Mission" | Set-Content (Join-Path $botDir "workspace\product\mission.md")
    New-Item -ItemType Directory -Path (Join-Path $conditionRoot ".git\refs\heads") -Force | Out-Null
    "ref: refs/heads/main" | Set-Content (Join-Path $conditionRoot ".git\HEAD")
    "abc123" | Set-Content (Join-Path $conditionRoot ".git\refs\heads\main")
    New-Item -ItemType Directory -Path (Join-Path $botDir "workspace\tasks\todo") -Force | Out-Null

    # Null/empty condition → always true
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition $null
    Assert-True -Name "Null condition returns true" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ""
    Assert-True -Name "Empty string condition returns true" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @()
    Assert-True -Name "Empty array condition returns true" -Condition $result

    # Simple path existence
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".bot/workspace/product/mission.md"
    Assert-True -Name "Existing file returns true" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".bot/workspace/product/nonexistent.md"
    Assert-True -Name "Non-existing file returns false" -Condition (-not $result)

    # Negation with ! prefix
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition "!.bot/workspace/product/mission.md"
    Assert-True -Name "! negation of existing file returns false" -Condition (-not $result)

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition "!.bot/workspace/product/nonexistent.md"
    Assert-True -Name "! negation of non-existing file returns true" -Condition $result

    # Glob * pattern
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".git/refs/heads/*"
    Assert-True -Name "Glob * matching files returns true" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".bot/workspace/tasks/todo/*"
    Assert-True -Name "Glob * matching empty dir returns false" -Condition (-not $result)

    # Negated glob
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition "!.git/refs/heads/*"
    Assert-True -Name "Negated glob with matches returns false" -Condition (-not $result)

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition "!.bot/workspace/tasks/todo/*"
    Assert-True -Name "Negated glob with no matches returns true" -Condition $result

    # Array AND conditions (all must match)
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        ".bot/workspace/product/mission.md",
        ".git/refs/heads/*"
    )
    Assert-True -Name "Array AND: both true → true" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        ".bot/workspace/product/mission.md",
        ".bot/workspace/product/nonexistent.md"
    )
    Assert-True -Name "Array AND: one false → false" -Condition (-not $result)

    # Mixed array: negation + existence
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        "!.bot/workspace/product/mission.md",
        ".git/refs/heads/*"
    )
    Assert-True -Name "Array AND: negated true + glob true → false" -Condition (-not $result)

    # Real workflow.json pattern: new_project mode
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        "!.bot/workspace/product/mission.md",
        "!.git/refs/heads/*"
    )
    Assert-True -Name "New project mode (no docs, no commits) → false when both exist" -Condition (-not $result)

    # Real workflow.json pattern: existing_code mode
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        "!.bot/workspace/product/mission.md",
        ".git/refs/heads/*"
    )
    Assert-True -Name "Existing code mode (no docs, has commits) → false when docs exist" -Condition (-not $result)

    # Real workflow.json pattern: has_docs mode
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".bot/workspace/product/mission.md"
    Assert-True -Name "Has docs mode (mission exists) → true" -Condition $result

    # Legacy file_exists: compat
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition "file_exists:workspace/product/mission.md"
    Assert-True -Name "Legacy file_exists: prefix resolves under .bot/" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition "file_exists:workspace/product/nonexistent.md"
    Assert-True -Name "Legacy file_exists: prefix for missing file → false" -Condition (-not $result)

    # Directory existence
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".bot/workspace/product"
    Assert-True -Name "Directory path returns true when exists" -Condition $result

    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition ".bot/workspace/nonexistent"
    Assert-True -Name "Directory path returns false when missing" -Condition (-not $result)

} finally {
    Remove-Item -Path $conditionRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# Read-WorkflowManifest
# ═══════════════════════════════════════════════════════════════════

Write-Host "  Read-WorkflowManifest" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if ($true) {
    # start-from-prompt workflow (canonical default after PR-5)
    $promptManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\start-from-prompt")
    Assert-Equal -Name "start-from-prompt manifest name" -Expected "start-from-prompt" -Actual $promptManifest.name
    Assert-True -Name "start-from-prompt manifest has tasks" `
        -Condition ($promptManifest.tasks -and $promptManifest.tasks.Count -gt 0) `
        -Message "Expected tasks array, got: $($promptManifest.tasks.Count)"
    Assert-True -Name "start-from-prompt manifest has form.modes" `
        -Condition ($null -ne $promptManifest.form -and $null -ne $promptManifest.form.modes -and $promptManifest.form.modes.Count -gt 0) `
        -Message "Expected form.modes array"

    $newProjectMode = $promptManifest.form.modes | Where-Object { $_.id -eq 'new_project' }
    Assert-True -Name "start-from-prompt form.modes has new_project" `
        -Condition ($null -ne $newProjectMode) -Message "new_project mode not found"
    if ($newProjectMode) {
        Assert-True -Name "new_project mode has condition array" `
            -Condition ($newProjectMode.condition -is [array] -or $newProjectMode.condition -is [System.Collections.IList]) `
            -Message "Expected condition to be array"
        Assert-True -Name "new_project mode has label" `
            -Condition (-not [string]::IsNullOrEmpty($newProjectMode.label)) -Message "Missing label"
        Assert-True -Name "new_project mode has button" `
            -Condition (-not [string]::IsNullOrEmpty($newProjectMode.button)) -Message "Missing button"
    }

    $hasDocsMode = $promptManifest.form.modes | Where-Object { $_.id -eq 'has_docs' }
    Assert-True -Name "start-from-prompt form.modes has has_docs (hidden)" `
        -Condition ($null -ne $hasDocsMode -and $hasDocsMode.hidden -eq $true) -Message "has_docs mode should be hidden"

    $taskNames = @($promptManifest.tasks | ForEach-Object { $_.name })
    $uniqueNames = @($taskNames | Sort-Object -Unique)
    Assert-Equal -Name "start-from-prompt manifest task names are unique" `
        -Expected $taskNames.Count -Actual $uniqueNames.Count

    foreach ($task in $promptManifest.tasks) {
        if ($task.depends_on) {
            foreach ($dep in @($task.depends_on)) {
                Assert-True -Name "start-from-prompt task '$($task.name)' dep '$dep' exists" `
                    -Condition ($dep -in $taskNames) `
                    -Message "Dependency '$dep' not found in task names"
            }
        }
    }

    # fast-prompt workflow
    $fastManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\fast-prompt")
    Assert-Equal -Name "fast-prompt manifest name" -Expected "fast-prompt" -Actual $fastManifest.name
    Assert-True -Name "fast-prompt manifest has exactly one task" `
        -Condition ($fastManifest.tasks -and @($fastManifest.tasks).Count -eq 1) `
        -Message "Expected 1 task, got: $(@($fastManifest.tasks).Count)"

    $fastTask = @($fastManifest.tasks)[0]
    Assert-Equal -Name "fast-prompt task type is prompt_template" -Expected "prompt_template" -Actual $fastTask.type
    Assert-Equal -Name "fast-prompt task uses minimal prompt template" `
        -Expected "recipes/prompts/00-fast-prompt.md" -Actual $fastTask.prompt
    Assert-PathExists -Name "fast-prompt prompt template exists" `
        -Path (Join-Path $repoRoot "content\workflows\fast-prompt\recipes\prompts\00-fast-prompt.md")

    $fastMode = @($fastManifest.form.modes)[0]
    Assert-Equal -Name "fast-prompt form mode label" -Expected "Fast Prompt" -Actual $fastMode.label
    Assert-True -Name "fast-prompt form disables interview" -Condition ($fastMode.show_interview -eq $false)
    Assert-True -Name "fast-prompt form keeps prompt input visible" -Condition ($fastMode.show_prompt -eq $true)

    $fastSettingsPath = Join-Path $repoRoot "content\workflows\fast-prompt\settings\settings.default.json"
    $fastSettings = Get-Content $fastSettingsPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "fast-prompt settings selects workflow" -Expected "fast-prompt" -Actual $fastSettings.workflow
    Assert-Equal -Name "fast-prompt settings uses fast execution model" -Expected "fast" -Actual $fastSettings.execution.model
    $fastSchemaErrors = @(Test-WorkflowManifestSchema -Manifest $fastManifest -WorkflowName 'fast-prompt')
    Assert-Equal -Name "fast-prompt manifest schema is valid" -Expected 0 -Actual $fastSchemaErrors.Count

    # start-from-jira workflow
    $jiraManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\start-from-jira")
    Assert-Equal -Name "Jira manifest name" -Expected "start-from-jira" -Actual $jiraManifest.name
    Assert-True -Name "Jira manifest has requires.env_vars" `
        -Condition ($jiraManifest.requires -and $jiraManifest.requires.env_vars -and @($jiraManifest.requires.env_vars).Count -gt 0) `
        -Message "Expected env_vars in requires"
    Assert-True -Name "Jira manifest has requires.mcp_servers" `
        -Condition ($jiraManifest.requires.mcp_servers -and @($jiraManifest.requires.mcp_servers).Count -gt 0) `
        -Message "Expected mcp_servers in requires"
    Assert-True -Name "Jira manifest has requires.cli_tools" `
        -Condition ($jiraManifest.requires.cli_tools -and @($jiraManifest.requires.cli_tools).Count -gt 0) `
        -Message "Expected cli_tools in requires"
    Assert-True -Name "Jira manifest has domain.task_categories" `
        -Condition ($jiraManifest.domain -and $jiraManifest.domain.task_categories -and @($jiraManifest.domain.task_categories).Count -gt 0) `
        -Message "Expected task_categories in domain"
    Assert-True -Name "Jira manifest has barrier tasks" `
        -Condition (@($jiraManifest.tasks | Where-Object { $_.type -eq 'barrier' }).Count -gt 0) `
        -Message "Expected at least one barrier task"

    # Jira task dependency graph validation
    $jiraTaskNames = @($jiraManifest.tasks | ForEach-Object { $_.name })
    foreach ($task in $jiraManifest.tasks) {
        if ($task.depends_on) {
            foreach ($dep in @($task.depends_on)) {
                Assert-True -Name "Jira task '$($task.name)' dep '$dep' exists" `
                    -Condition ($dep -in $jiraTaskNames) `
                    -Message "Dependency '$dep' not found in jira task names"
            }
        }
    }

    # start-from-pr workflow
    $prManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\start-from-pr")
    Assert-Equal -Name "PR manifest name" -Expected "start-from-pr" -Actual $prManifest.name
    Assert-True -Name "PR manifest has tasks" `
        -Condition ($prManifest.tasks -and $prManifest.tasks.Count -ge 3) `
        -Message "Expected at least 3 tasks, got: $($prManifest.tasks.Count)"
    Assert-True -Name "PR manifest has requires.cli_tools" `
        -Condition ($prManifest.requires -and $prManifest.requires.cli_tools -and @($prManifest.requires.cli_tools).Count -gt 0) `
        -Message "Expected cli_tools in requires"

    # start-from-repo workflow
    $repoManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\start-from-repo")
    Assert-Equal -Name "Repo manifest name" -Expected "start-from-repo" -Actual $repoManifest.name
    Assert-True -Name "Repo manifest has tasks" `
        -Condition ($repoManifest.tasks -and $repoManifest.tasks.Count -ge 8) `
        -Message "Expected at least 8 tasks, got: $($repoManifest.tasks.Count)"
    Assert-True -Name "Repo manifest has requires.mcp_servers" `
        -Condition ($repoManifest.requires -and $repoManifest.requires.mcp_servers -and @($repoManifest.requires.mcp_servers).Count -gt 0) `
        -Message "Expected mcp_servers in requires"
    Assert-True -Name "Repo manifest has requires.cli_tools" `
        -Condition ($repoManifest.requires -and $repoManifest.requires.cli_tools -and @($repoManifest.requires.cli_tools).Count -gt 0) `
        -Message "Expected cli_tools in requires"
    Assert-True -Name "Repo manifest has domain.task_categories" `
        -Condition ($repoManifest.domain -and $repoManifest.domain.task_categories -and @($repoManifest.domain.task_categories).Count -gt 0) `
        -Message "Expected task_categories in domain"

    # Repo task dependency graph validation
    $repoTaskNames = @($repoManifest.tasks | ForEach-Object { $_.name })
    foreach ($task in $repoManifest.tasks) {
        if ($task.depends_on) {
            foreach ($dep in @($task.depends_on)) {
                Assert-True -Name "Repo task '$($task.name)' dep '$dep' exists" `
                    -Condition ($dep -in $repoTaskNames) `
                    -Message "Dependency '$dep' not found in repo task names"
            }
        }
    }

    # Non-existent workflow dir returns defaults
    $emptyManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\nonexistent-workflow")
    Assert-True -Name "Non-existent dir returns default manifest with name" `
        -Condition ($emptyManifest.name -eq "nonexistent-workflow") `
        -Message "Expected name from dir leaf"
    Assert-True -Name "Non-existent dir returns empty tasks" `
        -Condition ($emptyManifest.tasks.Count -eq 0) `
        -Message "Expected empty tasks"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TEST-VALIDWORKFLOWDIR
# ═══════════════════════════════════════════════════════════════════

Write-Host "  TEST-VALIDWORKFLOWDIR" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Real workflow folder
Assert-True -Name "Test-ValidWorkflowDir true for real workflow" `
    -Condition (Test-ValidWorkflowDir -Dir (Join-Path $repoRoot "content\workflows\start-from-prompt")) `
    -Message "Expected true for workflow with a populated workflow.json"

# Non-existent directory
Assert-True -Name "Test-ValidWorkflowDir false for non-existent dir" `
    -Condition (-not (Test-ValidWorkflowDir -Dir (Join-Path $repoRoot "content\workflows\definitely-not-here"))) `
    -Message "Expected false for non-existent directory"

# Synthetic temp dirs for the missing/empty/whitespace cases
$tempProbeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-validdir-probe-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
try {
    $noJSON = Join-Path $tempProbeRoot "no-JSON"
    New-Item -ItemType Directory -Path $noJSON -Force | Out-Null
    Assert-True -Name "Test-ValidWorkflowDir false when workflow.json missing" `
        -Condition (-not (Test-ValidWorkflowDir -Dir $noJSON)) `
        -Message "Expected false when workflow.json is absent"

    $emptyJSON = Join-Path $tempProbeRoot "empty-JSON"
    New-Item -ItemType Directory -Path $emptyJSON -Force | Out-Null
    New-Item -ItemType File      -Path (Join-Path $emptyJSON "workflow.json") -Force | Out-Null
    Assert-True -Name "Test-ValidWorkflowDir false when workflow.json empty" `
        -Condition (-not (Test-ValidWorkflowDir -Dir $emptyJSON)) `
        -Message "Expected false when workflow.json exists but is empty"

    $wsJSON = Join-Path $tempProbeRoot "ws-JSON"
    New-Item -ItemType Directory -Path $wsJSON -Force | Out-Null
    "`r`n   `r`n`t" | Set-Content -Path (Join-Path $wsJSON "workflow.json")
    Assert-True -Name "Test-ValidWorkflowDir false when workflow.json whitespace-only" `
        -Condition (-not (Test-ValidWorkflowDir -Dir $wsJSON)) `
        -Message "Expected false when workflow.json is whitespace-only"

    $okJSON = Join-Path $tempProbeRoot "ok-JSON"
    New-Item -ItemType Directory -Path $okJSON -Force | Out-Null
    '{"name":"probe","description":"ok"}' | Set-Content -Path (Join-Path $okJSON "workflow.json")
    Assert-True -Name "Test-ValidWorkflowDir true when workflow.json has content" `
        -Condition (Test-ValidWorkflowDir -Dir $okJSON) `
        -Message "Expected true when workflow.json has any non-whitespace content"
} finally {
    if (Test-Path $tempProbeRoot) {
        Remove-Item -Path $tempProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CONVERT-MANIFESTREQUIRESTOPREFLIGHTCHECKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CONVERT-MANIFESTREQUIRESTOPREFLIGHTCHECKS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Hashtable input (as parsed from JSON)
$requires = @{
    env_vars = @(
        @{ var = "MY_API_KEY"; name = "API Key"; message = "API key required"; hint = "Set MY_API_KEY in .env.local" }
        @{ var = "MY_SECRET"; name = "Secret"; message = "Secret required"; hint = "Set MY_SECRET" }
    )
    mcp_servers = @(
        @{ name = "dotbot"; message = "Dotbot required"; hint = "Run init" }
    )
    cli_tools = @(
        @{ name = "git"; message = "Git required"; hint = "Install git" }
        @{ name = "az"; message = "Azure CLI required"; hint = "Install az" }
    )
}

$checks = @(Convert-ManifestRequiresToPreflightChecks -Requires $requires)
Assert-Equal -Name "Total preflight checks from mixed requires" -Expected 5 -Actual $checks.Count

$envChecks = @($checks | Where-Object { $_.type -eq 'env_var' })
Assert-Equal -Name "env_var checks count" -Expected 2 -Actual $envChecks.Count
Assert-Equal -Name "First env_var has correct var" -Expected "MY_API_KEY" -Actual $envChecks[0].var
Assert-Equal -Name "First env_var has correct hint" -Expected "Set MY_API_KEY in .env.local" -Actual $envChecks[0].hint

$mcpChecks = @($checks | Where-Object { $_.type -eq 'mcp_server' })
Assert-Equal -Name "mcp_server checks count" -Expected 1 -Actual $mcpChecks.Count
Assert-Equal -Name "mcp_server has correct name" -Expected "dotbot" -Actual $mcpChecks[0].name

$cliChecks = @($checks | Where-Object { $_.type -eq 'cli_tool' })
Assert-Equal -Name "cli_tool checks count" -Expected 2 -Actual $cliChecks.Count

# Empty requires
$emptyChecks = @(Convert-ManifestRequiresToPreflightChecks -Requires @{})
Assert-Equal -Name "Empty requires returns empty checks" -Expected 0 -Actual $emptyChecks.Count

# Requires with only env_vars
$envOnlyChecks = @(Convert-ManifestRequiresToPreflightChecks -Requires @{
    env_vars = @(@{ var = "SINGLE_VAR"; name = "Single" })
})
Assert-Equal -Name "env_vars-only requires returns 1 check" -Expected 1 -Actual $envOnlyChecks.Count

# Schema error path: missing 'var' in env_vars now throws (issue #319) instead
# of silently dropping the entry.
$throwCaught = $false
try {
    Convert-ManifestRequiresToPreflightChecks -Requires @{
        env_vars = @(@{ name = "GITHUB_TOKEN"; message = "required" })
    } -WorkflowName "test-wf" | Out-Null
} catch {
    $throwCaught = $true
    Assert-True -Name "env_vars missing 'var' throws naming the field" `
        -Condition ($_.Exception.Message -match "missing the required 'var' field") `
        -Message "Error message did not name the missing field. Got: $($_.Exception.Message)"
    Assert-True -Name "env_vars missing 'var' throws naming the workflow" `
        -Condition ($_.Exception.Message -match "test-wf") `
        -Message "Error message did not name the workflow"
}
Assert-True -Name "env_vars missing 'var' throws (was silent skip)" `
    -Condition $throwCaught `
    -Message "Convert-ManifestRequiresToPreflightChecks should throw on missing 'var', not silent-skip"

# Schema error: missing 'name' in mcp_servers
$throwCaught = $false
try {
    Convert-ManifestRequiresToPreflightChecks -Requires @{
        mcp_servers = @(@{ message = "required" })
    } | Out-Null
} catch { $throwCaught = $true }
Assert-True -Name "mcp_servers missing 'name' throws" -Condition $throwCaught

# Schema error: missing 'name' in cli_tools
$throwCaught = $false
try {
    Convert-ManifestRequiresToPreflightChecks -Requires @{
        cli_tools = @(@{ message = "required" })
    } | Out-Null
} catch { $throwCaught = $true }
Assert-True -Name "cli_tools missing 'name' throws" -Condition $throwCaught

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TEST-WORKFLOWMANIFESTSCHEMA
# ═══════════════════════════════════════════════════════════════════

Write-Host "  TEST-WORKFLOWMANIFESTSCHEMA" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Valid manifest produces no errors
$validManifest = @{
    name = "valid-wf"
    requires = @{
        env_vars = @(@{ var = "API_KEY"; name = "API Key"; message = "required" })
        mcp_servers = @(@{ name = "dotbot"; message = "required" })
        cli_tools = @(@{ name = "git"; message = "required" })
    }
}
$validErrors = @(Test-WorkflowManifestSchema -Manifest $validManifest)
Assert-Equal -Name "Valid manifest returns 0 errors" -Expected 0 -Actual $validErrors.Count

# Manifest with no requires returns 0 errors
$noReqErrors = @(Test-WorkflowManifestSchema -Manifest @{ name = "x" })
Assert-Equal -Name "Manifest without requires returns 0 errors" -Expected 0 -Actual $noReqErrors.Count

# env_vars missing 'var' (the original bug from issue #319): one error
$badEnvVars = @{
    name = "bad-wf"
    requires = @{
        env_vars = @(@{ name = "GITHUB_TOKEN"; message = "required" })
    }
}
$badErrors = @(Test-WorkflowManifestSchema -Manifest $badEnvVars)
Assert-Equal -Name "env_vars missing 'var' produces 1 error" -Expected 1 -Actual $badErrors.Count
Assert-True -Name "Error names the workflow" `
    -Condition ($badErrors[0] -match "bad-wf") `
    -Message "Workflow name not in error: $($badErrors[0])"
Assert-True -Name "Error names the missing field" `
    -Condition ($badErrors[0] -match "'var'") `
    -Message "Field name not in error"
Assert-True -Name "Error shows the offending entry" `
    -Condition ($badErrors[0] -match "GITHUB_TOKEN") `
    -Message "Offending entry not shown"
Assert-True -Name "Error shows the expected schema" `
    -Condition ($badErrors[0] -match "Expected schema:") `
    -Message "Expected schema line missing"

# Multiple bad entries each produce their own error
$multiBad = @{
    name = "multi-bad"
    requires = @{
        env_vars = @(
            @{ name = "ENTRY_ONE" },
            @{ var = "OK_VAR" },
            @{ name = "ENTRY_TWO" }
        )
        mcp_servers = @(@{ message = "missing name" })
        cli_tools = @(@{ message = "missing name" })
    }
}
$multiErrors = @(Test-WorkflowManifestSchema -Manifest $multiBad)
Assert-Equal -Name "Multiple bad entries produce 4 errors (2 env + 1 mcp + 1 cli)" `
    -Expected 4 -Actual $multiErrors.Count

# WorkflowName param overrides manifest.name in error output
$overrideErrors = @(Test-WorkflowManifestSchema -Manifest @{
    requires = @{ env_vars = @(@{ name = "X" }) }
} -WorkflowName "override-name")
Assert-True -Name "WorkflowName param appears in error" `
    -Condition ($overrideErrors[0] -match "override-name") `
    -Message "Override name not honored"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CONVERT-MANIFESTTASKSTOPHASES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CONVERT-MANIFESTTASKSTOPHASES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$sampleTasks = @(
    @{ name = "Fetch Jira Context"; type = "prompt" }
    @{ name = "Execute Research"; type = "barrier"; optional = $true }
    @{ name = "Generate Plans" }
)

$phases = @(Convert-ManifestTasksToPhases -Tasks $sampleTasks)
Assert-Equal -Name "Phase count matches task count" -Expected 3 -Actual $phases.Count
Assert-Equal -Name "Phase 1 ID is slugified" -Expected "fetch-jira-context" -Actual $phases[0].id
Assert-Equal -Name "Phase 1 name preserved" -Expected "Fetch Jira Context" -Actual $phases[0].name
Assert-Equal -Name "Phase 1 type preserved" -Expected "prompt" -Actual $phases[0].type
Assert-Equal -Name "Phase 2 type is barrier" -Expected "barrier" -Actual $phases[1].type
Assert-True -Name "Phase 2 optional is true" -Condition ($phases[1].optional -eq $true)
Assert-Equal -Name "Phase 3 type defaults to prompt" -Expected "prompt" -Actual $phases[2].type
Assert-True -Name "Phase 3 optional defaults to false" -Condition ($phases[2].optional -eq $false)

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# ENSURE-MANIFESTTASKIDS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  ENSURE-MANIFESTTASKIDS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Hashtable tasks without id — should generate slug from name
$htTasks = @(
    @{ name = "Product Documents"; type = "prompt" }
    @{ name = "Generate Decisions"; type = "prompt" }
)
Ensure-ManifestTaskIds -Tasks $htTasks
Assert-Equal -Name "Hashtable task 1 id generated" -Expected "product-documents" -Actual $htTasks[0]['id']
Assert-Equal -Name "Hashtable task 2 id generated" -Expected "generate-decisions" -Actual $htTasks[1]['id']

# Hashtable task WITH existing id — should be preserved
$htPreserve = @( @{ name = "Some Task"; type = "prompt"; id = "custom-id" } )
Ensure-ManifestTaskIds -Tasks $htPreserve
Assert-Equal -Name "Existing hashtable id preserved" -Expected "custom-id" -Actual $htPreserve[0]['id']

# PSObject tasks (from ConvertFrom-Json)
$jsonTasks = @(ConvertFrom-Json '[{"name":"Pull Request Context","type":"prompt"},{"name":"Planning Tasks","type":"task_gen"}]')
Ensure-ManifestTaskIds -Tasks $jsonTasks
Assert-Equal -Name "PSObject task 1 id generated" -Expected "pull-request-context" -Actual $jsonTasks[0].id
Assert-Equal -Name "PSObject task 2 id generated" -Expected "planning-tasks" -Actual $jsonTasks[1].id

# PSObject task WITH existing id — should be preserved
$jsonPreserve = @(ConvertFrom-Json '[{"name":"Some Task","type":"prompt","id":"keep-me"}]')
Ensure-ManifestTaskIds -Tasks $jsonPreserve
Assert-Equal -Name "Existing PSObject id preserved" -Expected "keep-me" -Actual $jsonPreserve[0].id

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# NEW-WORKFLOWTASK
# ═══════════════════════════════════════════════════════════════════

Write-Host "  NEW-WORKFLOWTASK" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1") -Force -DisableNameChecking

$taskRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-wftask-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
$taskBotDir = Join-Path $taskRoot ".bot"
New-Item -ItemType Directory -Path (Join-Path $taskBotDir "workspace\tasks") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $taskBotDir ".control") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $taskBotDir "content/agents/code-reviewer") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $taskBotDir "content/skills/code-review") -Force | Out-Null
Set-Content -Path (Join-Path $taskBotDir "content/agents/code-reviewer/AGENT.md") -Value '# code reviewer'
Set-Content -Path (Join-Path $taskBotDir "content/skills/code-review/SKILL.md") -Value '# code review skill'

try {
    $runJira    = Initialize-WorkflowRun -BotRoot $taskBotDir -WorkflowName 'start-from-jira' -StartedBy 'test:wfmanifest'
    $runDefault = Initialize-WorkflowRun -BotRoot $taskBotDir -WorkflowName 'default'         -StartedBy 'test:wfmanifest'
    $runScoring = Initialize-WorkflowRun -BotRoot $taskBotDir -WorkflowName 'scoring'         -StartedBy 'test:wfmanifest'

    # Basic prompt task
    $taskDef = @{
        name = "Fetch Jira Context"
        type = "prompt"
        workflow = "00-interview.md"
        priority = 1
        outputs = @("briefing/jira-context.md")
        condition = ".bot/workspace/product/research-repos.md"
        on_failure = "halt"
    }

    $result = New-WorkflowTask -Run $runJira -TaskDef $taskDef
    Assert-True -Name "New-WorkflowTask returns id (t_…)" `
        -Condition ([string]$result.id -cmatch '^t_[A-Za-z0-9]{8}$') -Message "id must be canonical"
    Assert-Equal -Name "New-WorkflowTask returns name" -Expected "Fetch Jira Context" -Actual $result.name
    Assert-True -Name "New-WorkflowTask returns file_path" `
        -Condition (-not [string]::IsNullOrEmpty($result.file_path)) -Message "No file_path returned"
    Assert-PathExists -Name "Task JSON file created" -Path $result.file_path

    $taskJson = Get-Content -Path $result.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Task JSON has correct name"     -Expected "Fetch Jira Context" -Actual $taskJson.name
    Assert-Equal -Name "Task JSON has correct type"     -Expected "prompt_template"    -Actual $taskJson.type
    Assert-Equal -Name "Task JSON legacy workflow prompt is executor.prompt" -Expected "00-interview.md" -Actual $taskJson.extensions.executor.prompt
    Assert-Equal -Name "Task JSON provenance.workflow"  -Expected "start-from-jira"    -Actual $taskJson.provenance.workflow
    Assert-Equal -Name "Task JSON provenance.run_id"     -Expected $runJira.run_id      -Actual $taskJson.provenance.run_id
    Assert-Equal -Name "Task JSON has correct priority"  -Expected 1                    -Actual $taskJson.priority
    Assert-Equal -Name "Task JSON has correct status"    -Expected "todo"               -Actual $taskJson.status
    Assert-Equal -Name "Task JSON has schema_version"    -Expected 2                    -Actual $taskJson.schema_version
    Assert-True  -Name "Task JSON has outputs" `
        -Condition (@($taskJson.outputs).Count -eq 1) -Message "Expected 1 output"
    Assert-True  -Name "extensions.workflow.condition is set" `
        -Condition ($taskJson.extensions.workflow.condition -eq ".bot/workspace/product/research-repos.md") `
        -Message "condition must land under extensions.workflow"
    Assert-Equal -Name "prompt workflow file maps to executor prompt" `
        -Expected "00-interview.md" `
        -Actual $taskJson.extensions.executor.prompt
    Assert-Equal -Name "extensions.workflow.on_failure preserved" -Expected "halt" -Actual $taskJson.extensions.workflow.on_failure

    $conditionRun = Initialize-WorkflowRun -BotRoot $taskBotDir -WorkflowName 'condition-selection' -StartedBy 'test:wfmanifest'
    $conditioned = New-WorkflowTask -Run $conditionRun -TaskDef @{
        name = "Conditioned Prompt"
        type = "prompt"
        workflow = "01-plan-product.md"
        condition = ".bot/workspace/product/missing-condition-file.md"
        priority = 1000
    }
    $eligibleConditionPeer = New-WorkflowTask -Run $conditionRun -TaskDef @{
        name = "Eligible Prompt"
        type = "prompt"
        workflow = "01-plan-product.md"
        priority = 999
    }

    $nextConditionTask = Get-NextWorkflowTask -BotRoot $taskBotDir -RunId $conditionRun.run_id
    Assert-Equal -Name "Get-NextWorkflowTask skips false manifest condition" `
        -Expected "Eligible Prompt" `
        -Actual $nextConditionTask.task.name

    $conditionedJson = Get-Content -Path $conditioned.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "false condition task is marked skipped" -Expected "skipped" -Actual $conditionedJson.status
    Assert-Equal -Name "false condition skip reason is persisted" `
        -Expected "condition-not-met" `
        -Actual $conditionedJson.extensions.runner.skip_reason

    $nextUnscopedTask = Get-NextWorkflowTask -BotRoot $taskBotDir
    Assert-True -Name "Get-NextWorkflowTask supports unscoped pending selection" `
        -Condition ($nextUnscopedTask.success -and $nextUnscopedTask.task) `
        -Message "Expected unscoped pending selection to return a task"

    # Barrier task — verify boolean defaults. Dependencies must be canonical
    # task IDs, so the named tasks must be created BEFORE the barrier that
    # depends on them so the run's name_to_id_map can resolve them.
    $planInternet  = New-WorkflowTask -Run $runJira -TaskDef @{ name = "Plan Internet Research";  type = "prompt"; priority = 2 }
    $planAtlassian = New-WorkflowTask -Run $runJira -TaskDef @{ name = "Plan Atlassian Research"; type = "prompt"; priority = 2 }

    $barrierDef = @{
        name = "Execute Research"
        type = "barrier"
        depends_on = @("Plan Internet Research", "Plan Atlassian Research")
        optional = $true
        priority = 6
    }

    $barrierResult = New-WorkflowTask -Run $runJira -TaskDef $barrierDef
    $barrierJson = Get-Content -Path $barrierResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Barrier task type" -Expected "barrier" -Actual $barrierJson.type
    Assert-True  -Name "Barrier task extensions.executor.skip_analysis defaults to true" `
        -Condition ($barrierJson.extensions.executor.skip_analysis -eq $true) `
        -Message "skip_analysis defaults to true for non-prompt types"
    Assert-True  -Name "Barrier task has no skip_worktree on extensions.executor" `
        -Condition (-not $barrierJson.extensions.executor.PSObject.Properties['skip_worktree']) `
        -Message "skip_worktree should not be emitted"
    Assert-Equal -Name "Barrier task has 2 dependencies (resolved to t_ IDs)" -Expected 2 -Actual @($barrierJson.dependencies).Count
    Assert-True  -Name "Barrier deps[0] resolves to plan-internet's id" `
        -Condition ($barrierJson.dependencies[0] -eq $planInternet.id)
    Assert-True  -Name "Barrier deps[1] resolves to plan-atlassian's id" `
        -Condition ($barrierJson.dependencies[1] -eq $planAtlassian.id)

    # Dangling depends-on gets recorded under extensions.workflow.unresolved_dependencies
    $danglerResult = New-WorkflowTask -Run $runJira -TaskDef @{ name = "Dangling Task"; type = "prompt"; depends_on = @("Never Defined"); priority = 99 }
    $danglerJson = Get-Content -Path $danglerResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Dangling dep produces 0 resolved dependencies" -Expected 0 -Actual @($danglerJson.dependencies).Count
    Assert-True  -Name "Dangling dep is recorded under extensions.workflow.unresolved_dependencies" `
        -Condition (@($danglerJson.extensions.workflow.unresolved_dependencies) -contains 'Never Defined')

    # Script task
    $scriptDef = @{
        name = "Task Group Expansion"
        type = "script"
        script = "Expand-TaskGroups.ps1"
        priority = 4
    }

    $scriptResult = New-WorkflowTask -Run $runDefault -TaskDef $scriptDef
    $scriptJson = Get-Content -Path $scriptResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Script task type"                   -Expected "script"               -Actual $scriptJson.type
    Assert-Equal -Name "Script task provenance.workflow"     -Expected "default"              -Actual $scriptJson.provenance.workflow
    Assert-Equal -Name "Script task extensions.executor.script_path" -Expected "Expand-TaskGroups.ps1" -Actual $scriptJson.extensions.executor.script_path

    # task_gen + workflow: "*.md" → should become prompt_template with prompt field
    $taskGenPromptDef = @{
        name     = "Plan Internet Research (md)"
        type     = "task_gen"
        workflow = "02a-plan-internet-research.md"
        priority = 1
    }
    $tgpResult = New-WorkflowTask -Run $runDefault -TaskDef $taskGenPromptDef
    $tgpJson = Get-Content -Path $tgpResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "task_gen+workflow .md maps to prompt_template type" -Expected "prompt_template" -Actual $tgpJson.type
    Assert-Equal -Name "task_gen+workflow .md sets executor.prompt reference"  -Expected "02a-plan-internet-research.md" -Actual $tgpJson.extensions.executor.prompt
    Assert-Equal -Name "task_gen+workflow .md provenance.workflow is the run name" -Expected "default" -Actual $tgpJson.provenance.workflow

    $promptRefDef = @{
        name     = "Project Interview"
        type     = "prompt"
        prompt   = "project-interview"
        priority = 1
    }
    $promptRefResult = New-WorkflowTask -Run $runDefault -TaskDef $promptRefDef
    $promptRefJson = Get-Content -Path $promptRefResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "prompt field maps prompt task to prompt_template" -Expected "prompt_template" -Actual $promptRefJson.type
    Assert-Equal -Name "prompt field preserved as executor.prompt reference" -Expected "project-interview" -Actual $promptRefJson.extensions.executor.prompt

    $contentDepsDef = @{
        name = "Task With Content Dependencies"
        type = "prompt"
        applicable_agents = @("code-reviewer")
        applicable_skills = @("content/skills/code-review/SKILL.md")
        priority = 1
    }
    $contentDepsResult = New-WorkflowTask -Run $runDefault -TaskDef $contentDepsDef
    $contentDepsJson = Get-Content -Path $contentDepsResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "workflow applicable_agents resolves to content path" `
        -Expected ".bot/content/agents/code-reviewer/AGENT.md" `
        -Actual @($contentDepsJson.extensions.workflow.applicable_agents)[0]
    Assert-Equal -Name "workflow applicable_skills resolves to content path" `
        -Expected ".bot/content/skills/code-review/SKILL.md" `
        -Actual @($contentDepsJson.extensions.workflow.applicable_skills)[0]

    # task_gen + workflow: non-.md value → should stay task_gen
    $taskGenFilterDef = @{
        name     = "Generate Scoring Tasks"
        type     = "task_gen"
        workflow = "scoring"
        script   = "generate-scoring-tasks.ps1"
        priority = 2
    }
    $tgfResult = New-WorkflowTask -Run $runScoring -TaskDef $taskGenFilterDef
    $tgfJson = Get-Content -Path $tgfResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "task_gen+non-.md stays task_gen type" -Expected "task_gen" -Actual $tgfJson.type
    Assert-True  -Name "task_gen+non-.md has no extensions.executor.prompt" `
        -Condition (-not $tgfJson.extensions.executor.PSObject.Properties['prompt']) `
        -Message "no prompt should be emitted for plain task_gen"

    # post_script — extensions.workflow.post_script
    $postScriptDef = @{
        name = "Task With Post Hook"
        type = "script"
        script = "do-work.ps1"
        post_script = "Complete-TaskGroupsPhase.ps1"
        priority = 5
    }
    $postResult = New-WorkflowTask -Run $runDefault -TaskDef $postScriptDef
    $postJson = Get-Content -Path $postResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "extensions.workflow.post_script preserved" `
        -Expected "Complete-TaskGroupsPhase.ps1" -Actual $postJson.extensions.workflow.post_script

    # Task without post_script — ensure field is absent
    $noPostDef = @{ name = "Task Without Post Hook"; type = "script"; script = "do-work.ps1"; priority = 5 }
    $noPostResult = New-WorkflowTask -Run $runDefault -TaskDef $noPostDef
    $noPostJson = Get-Content -Path $noPostResult.file_path -Raw | ConvertFrom-Json
    $hasPost = $noPostJson.extensions -and $noPostJson.extensions.PSObject.Properties['workflow'] -and `
               $noPostJson.extensions.workflow.PSObject.Properties['post_script']
    Assert-True -Name "post_script absent when not declared" -Condition (-not $hasPost)

    # Priority 0 — regression for priority=0 falsy bug
    $priorityZeroDef = @{
        name = "Highest Priority Task"
        type = "prompt"
        workflow = "00-launch.md"
        priority = 0
    }
    $pzResult = New-WorkflowTask -Run $runDefault -TaskDef $priorityZeroDef
    $pzJson = Get-Content -Path $pzResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Priority 0 preserved (not replaced by default)" -Expected 0 -Actual $pzJson.priority

} finally {
    Remove-Item -Path $taskRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# MERGE-MCPSERVERS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MERGE-MCPSERVERS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$mcpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-mcp-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $mcpRoot -Force | Out-Null

try {
    $mcpJsonPath = Join-Path $mcpRoot ".mcp.json"

    # Merge into non-existent file
    $servers = @{
        "my-server" = @{ command = "npx"; args = @("-y", "my-server") }
    }
    $added = Merge-McpServers -McpJsonPath $mcpJsonPath -WorkflowServers $servers
    Assert-Equal -Name "Merge into new file adds 1 server" -Expected 1 -Actual $added
    Assert-PathExists -Name ".mcp.json created" -Path $mcpJsonPath

    if (Test-Path $mcpJsonPath) {
        $mcpData = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json
        Assert-True -Name "Merged server exists in file" `
            -Condition ($null -ne $mcpData.mcpServers.'my-server') `
            -Message "my-server not found"
    }

    # Merge again — should skip existing
    $added2 = Merge-McpServers -McpJsonPath $mcpJsonPath -WorkflowServers $servers
    Assert-Equal -Name "Re-merge skips existing (0 added)" -Expected 0 -Actual $added2

    # Merge a new server alongside existing
    $newServers = @{
        "another-server" = @{ command = "node"; args = @("server.js") }
    }
    $added3 = Merge-McpServers -McpJsonPath $mcpJsonPath -WorkflowServers $newServers
    Assert-Equal -Name "Merge new alongside existing adds 1" -Expected 1 -Actual $added3

    if (Test-Path $mcpJsonPath) {
        $mcpData2 = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json
        Assert-True -Name "Both servers present" `
            -Condition ($null -ne $mcpData2.mcpServers.'my-server' -and $null -ne $mcpData2.mcpServers.'another-server') `
            -Message "Missing server after merge"
    }

} finally {
    Remove-Item -Path $mcpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CLEAR-WORKFLOWTASKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CLEAR-WORKFLOWTASKS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$clearRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-clear-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
$clearTasksDir = Join-Path $clearRoot "tasks"
foreach ($status in @("todo", "in-progress", "done")) {
    New-Item -ItemType Directory -Path (Join-Path $clearTasksDir $status) -Force | Out-Null
}

try {
    # Create tasks for two workflows
    $taskA = [ordered]@{ id = "a1"; name = "Task A1"; workflow = "workflow-alpha"; status = "todo" }
    $taskB = [ordered]@{ id = "b1"; name = "Task B1"; workflow = "workflow-beta"; status = "todo" }
    $taskA2 = [ordered]@{ id = "a2"; name = "Task A2"; workflow = "workflow-alpha"; status = "in-progress" }

    $taskA | ConvertTo-Json | Set-Content (Join-Path $clearTasksDir "todo\a1.json")
    $taskB | ConvertTo-Json | Set-Content (Join-Path $clearTasksDir "todo\b1.json")
    $taskA2 | ConvertTo-Json | Set-Content (Join-Path $clearTasksDir "in-progress\a2.json")

    # Clear workflow-alpha
    $removed = Clear-WorkflowTasks -TasksBaseDir $clearTasksDir -WorkflowName "workflow-alpha"
    Assert-Equal -Name "Clear removes workflow-alpha tasks" -Expected 2 -Actual $removed
    Assert-PathNotExists -Name "Task A1 removed from todo" -Path (Join-Path $clearTasksDir "todo\a1.json")
    Assert-PathNotExists -Name "Task A2 removed from in-progress" -Path (Join-Path $clearTasksDir "in-progress\a2.json")
    Assert-PathExists -Name "Task B1 preserved (different workflow)" -Path (Join-Path $clearTasksDir "todo\b1.json")

} finally {
    Remove-Item -Path $clearRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# NEW-ENVLOCALSCAFFOLD
# ═══════════════════════════════════════════════════════════════════

Write-Host "  NEW-ENVLOCALSCAFFOLD" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$envRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-env-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $envRoot -Force | Out-Null

try {
    $envLocalPath = Join-Path $envRoot ".env.local"

    # Create from scratch
    $envVars = @(
        @{ var = "API_KEY"; name = "API Key"; hint = "Get from dashboard" }
        @{ var = "SECRET"; name = "Secret Token"; hint = "Generate a token" }
    )
    New-EnvLocalScaffold -EnvLocalPath $envLocalPath -EnvVars $envVars

    Assert-PathExists -Name ".env.local created" -Path $envLocalPath
    if (Test-Path $envLocalPath) {
        $content = Get-Content $envLocalPath -Raw
        Assert-True -Name ".env.local contains API_KEY=" `
            -Condition ($content -match "API_KEY=") -Message "API_KEY entry not found"
        Assert-True -Name ".env.local contains SECRET=" `
            -Condition ($content -match "SECRET=") -Message "SECRET entry not found"
        Assert-True -Name ".env.local contains hint comment" `
            -Condition ($content -match "# API Key") -Message "Hint comment not found"
    }

    # Preserve existing values
    "API_KEY=my-existing-key`nEXTRA_VAR=keep-me" | Set-Content $envLocalPath
    New-EnvLocalScaffold -EnvLocalPath $envLocalPath -EnvVars $envVars

    if (Test-Path $envLocalPath) {
        $content2 = Get-Content $envLocalPath -Raw
        Assert-True -Name ".env.local preserves existing API_KEY value" `
            -Condition ($content2 -match "API_KEY=my-existing-key") `
            -Message "Existing value overwritten"
        Assert-True -Name ".env.local preserves extra vars not in manifest" `
            -Condition ($content2 -match "EXTRA_VAR=keep-me") `
            -Message "Extra var was lost"
        Assert-True -Name ".env.local adds missing SECRET=" `
            -Condition ($content2 -match "SECRET=") `
            -Message "Missing var not added"
    }

    # Schema error: missing 'var' now throws a clear error (issue #319) instead
    # of crashing with "Value cannot be null" from Hashtable.ContainsKey($null).
    Remove-Item $envLocalPath -Force -ErrorAction SilentlyContinue
    $throwCaught = $false
    $errMsg = ""
    try {
        New-EnvLocalScaffold -EnvLocalPath $envLocalPath `
            -EnvVars @(@{ name = "GITHUB_TOKEN"; message = "required" }) `
            -WorkflowName "test-wf"
    } catch {
        $throwCaught = $true
        $errMsg = $_.Exception.Message
    }
    Assert-True -Name "New-EnvLocalScaffold throws on missing 'var'" -Condition $throwCaught
    if ($throwCaught) {
        Assert-True -Name "Throw message names the workflow" `
            -Condition ($errMsg -match "test-wf") `
            -Message "Workflow name missing from error: $errMsg"
        Assert-True -Name "Throw message names the 'var' field" `
            -Condition ($errMsg -match "'var'") `
            -Message "Field name missing from error"
        Assert-True -Name "Throw message shows the offending entry" `
            -Condition ($errMsg -match "GITHUB_TOKEN") `
            -Message "Offending entry not shown"
        Assert-True -Name "Throw message shows expected schema" `
            -Condition ($errMsg -match "Expected schema:") `
            -Message "Expected schema line missing"
        Assert-True -Name "Throw is NOT the legacy null-key crash" `
            -Condition ($errMsg -notmatch "Value cannot be null") `
            -Message "Still hitting the legacy ContainsKey(`$null) crash"
    }

} finally {
    Remove-Item -Path $envRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW JSON SCHEMA VALIDATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKFLOW JSON SCHEMA" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if ($true) {
    $workflowProfiles = @("start-from-prompt", "start-from-jira", "start-from-pr", "start-from-repo")

    foreach ($wfProfile in $workflowProfiles) {
        $workflowPath = Join-Path $repoRoot "content\workflows\$wfProfile\workflow.json"
        Assert-PathExists -Name "workflow.json exists: $wfProfile" -Path $workflowPath

        if (Test-Path $workflowPath) {
            $manifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "content\workflows\$wfProfile")

            # Required top-level fields
            Assert-True -Name "${wfProfile}: has name" `
                -Condition (-not [string]::IsNullOrEmpty($manifest.name)) -Message "Missing name"
            Assert-True -Name "${wfProfile}: has version" `
                -Condition (-not [string]::IsNullOrEmpty($manifest.version)) -Message "Missing version"
            Assert-True -Name "${wfProfile}: has min_dotbot_version" `
                -Condition (-not [string]::IsNullOrEmpty($manifest.min_dotbot_version)) -Message "Missing min_dotbot_version"
            Assert-True -Name "${wfProfile}: has tasks" `
                -Condition ($manifest.tasks -and $manifest.tasks.Count -gt 0) -Message "Empty tasks"

            # Each task must have name and priority
            foreach ($task in $manifest.tasks) {
                $tName = $task.name
                Assert-True -Name "$wfProfile task '$tName': has name" `
                    -Condition (-not [string]::IsNullOrEmpty($tName)) -Message "Task missing name"
                Assert-True -Name "$wfProfile task '$tName': has priority" `
                    -Condition ($null -ne $task.priority) -Message "Task missing priority"

                # Tasks with outputs should have string arrays
                if ($task.outputs) {
                    Assert-True -Name "$wfProfile task '$tName': outputs is array" `
                        -Condition ($task.outputs -is [array] -or $task.outputs -is [System.Collections.IList]) `
                        -Message "outputs should be array"
                }
            }

            # Priorities should be monotonically non-decreasing
            # Note: ties are allowed for mutually exclusive conditional tasks (e.g. Analyse Project / Product Documents)
            $priorities = @($manifest.tasks | ForEach-Object { [int]$_.priority })
            $isSorted = $true
            for ($i = 1; $i -lt $priorities.Count; $i++) {
                if ($priorities[$i] -lt $priorities[$i - 1]) { $isSorted = $false; break }
            }
            Assert-True -Name "${wfProfile}: priorities are non-decreasing" `
                -Condition $isSorted -Message "Priorities are not in ascending order"
        }
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# INVOKE-POSTSCRIPT (regression for andresharpe/dotbot#222)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  INVOKE-POSTSCRIPT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Provide no-op implementations of the theme/activity helpers that
# Dotbot.Task calls. These normally come from DotbotTheme.psm1 and the
# runtime, but we only care about Invoke-PostScript's own behaviour here.
function Write-Status { param($Message, $Type) }
function Write-ProcessActivity { param($Id, $ActivityType, $Message) }

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1") -Force -DisableNameChecking

$postRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-post-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $postRoot "src/runtime") -Force | Out-Null
# 'scripts/' is the workflow-manifest convention for per-workflow helper scripts
# resolved relative to $BotRoot — not framework cli scripts under src/cli/.
New-Item -ItemType Directory -Path (Join-Path $postRoot "scripts") -Force | Out-Null

try {
    # A post-script that writes a sentinel file and echoes its received parameters
    $sentinelDir = Join-Path $postRoot "sentinel"
    New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null

    $okScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
$sentinel = Join-Path $BotRoot "sentinel\ran.txt"
"BotRoot=$BotRoot`nProductDir=$ProductDir`nModel=$Model`nProcessId=$ProcessId`nSetting=$($Settings.foo)" |
    Set-Content $sentinel
exit 0
'@
    $okScript | Set-Content (Join-Path $postRoot "src/runtime/ok-post.ps1")

    $failScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
exit 7
'@
    $failScript | Set-Content (Join-Path $postRoot "src/runtime/fail-post.ps1")

    $scriptsDirScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
Set-Content (Join-Path $BotRoot "sentinel\scripts-ran.txt") "ok"
exit 0
'@
    $scriptsDirScript | Set-Content (Join-Path $postRoot "scripts\scripts-post.ps1")

    $settings = @{ foo = "bar" }
    $productDir = Join-Path $postRoot "workspace\product"

    # Happy path: default path resolution (src/runtime/<name>)
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "balanced" -ProcessId "proc-123" `
            -RawPostScript "ok-post.ps1"
    } catch { $threw = $true }
    Assert-True -Name "Invoke-PostScript: happy path does not throw" -Condition (-not $threw)
    Assert-PathExists -Name "Invoke-PostScript: sentinel file created" `
        -Path (Join-Path $postRoot "sentinel\ran.txt")
    if (Test-Path (Join-Path $postRoot "sentinel\ran.txt")) {
        $sentinelContent = Get-Content (Join-Path $postRoot "sentinel\ran.txt") -Raw
        Assert-True -Name "Invoke-PostScript: passes BotRoot" `
            -Condition ($sentinelContent -match [regex]::Escape("BotRoot=$postRoot"))
        Assert-True -Name "Invoke-PostScript: passes ProductDir" `
            -Condition ($sentinelContent -match [regex]::Escape("ProductDir=$productDir"))
        Assert-True -Name "Invoke-PostScript: passes Model" `
            -Condition ($sentinelContent -match "Model=balanced")
        Assert-True -Name "Invoke-PostScript: passes ProcessId" `
            -Condition ($sentinelContent -match "ProcessId=proc-123")
        Assert-True -Name "Invoke-PostScript: passes Settings hashtable" `
            -Condition ($sentinelContent -match "Setting=bar")
    }

    # Scripts/ prefix path resolution
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "balanced" -ProcessId "proc-123" `
            -RawPostScript "scripts/scripts-post.ps1"
    } catch { $threw = $true }
    Assert-True -Name "Invoke-PostScript: scripts/ prefix resolves under BotRoot/scripts" `
        -Condition (-not $threw)
    Assert-PathExists -Name "Invoke-PostScript: scripts/ sentinel created" `
        -Path (Join-Path $postRoot "sentinel\scripts-ran.txt")

    # Backslash separator normalisation (Unix safety)
    Remove-Item (Join-Path $postRoot "sentinel\scripts-ran.txt") -Force -ErrorAction SilentlyContinue
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "balanced" -ProcessId "proc-123" `
            -RawPostScript "scripts\scripts-post.ps1"
    } catch { $threw = $true }
    Assert-True -Name "Invoke-PostScript: backslash separator is normalised" `
        -Condition (-not $threw)

    # Failing exit code is surfaced as a throw
    $threw = $false
    $errMsg = $null
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "balanced" -ProcessId "proc-123" `
            -RawPostScript "fail-post.ps1"
    } catch { $threw = $true; $errMsg = $_.Exception.Message }
    Assert-True -Name "Invoke-PostScript: non-zero exit code throws" -Condition $threw
    Assert-True -Name "Invoke-PostScript: exit code 7 surfaced in error" `
        -Condition ($errMsg -match "7")

    # Missing script file is surfaced as a throw before any invocation
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "balanced" -ProcessId "proc-123" `
            -RawPostScript "does-not-exist.ps1"
    } catch { $threw = $true }
    Assert-True -Name "Invoke-PostScript: missing script throws" -Condition $threw

} finally {
    Remove-Item -Path $postRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# INVOKE-TASKPOSTSCRIPTIFPRESENT (wrapper used by task-runner branches)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  INVOKE-TASKPOSTSCRIPTIFPRESENT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$wrapRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-wrap-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $wrapRoot "src/runtime") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $wrapRoot "sentinel") -Force | Out-Null

try {
    # Reusable scripts from the previous section aren't available — create fresh
    $okScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
Set-Content (Join-Path $BotRoot "sentinel\wrap-ok.txt") "ran"
exit 0
'@
    $okScript | Set-Content (Join-Path $wrapRoot "src/runtime/wrap-ok.ps1")

    $failScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
exit 3
'@
    $failScript | Set-Content (Join-Path $wrapRoot "src/runtime/wrap-fail.ps1")

    $settings = @{}
    $productDir = Join-Path $wrapRoot "workspace\product"

    # No post_script declared → returns $null, no-op
    $taskNoHook = [pscustomobject]@{ name = "No hook"; post_script = $null }
    $result = Invoke-TaskPostScriptIfPresent -Task $taskNoHook -BotRoot $wrapRoot `
        -ProductDir $productDir -Settings $settings -Model "balanced" -ProcessId "p1"
    Assert-True -Name "Wrapper: no post_script returns null" -Condition ($null -eq $result)

    # Happy path → returns $null, sentinel exists
    $taskOk = [pscustomobject]@{ name = "Ok hook"; post_script = "wrap-ok.ps1" }
    $result = Invoke-TaskPostScriptIfPresent -Task $taskOk -BotRoot $wrapRoot `
        -ProductDir $productDir -Settings $settings -Model "balanced" -ProcessId "p1"
    Assert-True -Name "Wrapper: success returns null" -Condition ($null -eq $result)
    Assert-PathExists -Name "Wrapper: success ran the script" `
        -Path (Join-Path $wrapRoot "sentinel\wrap-ok.txt")

    # Failure → returns error string, does not throw
    $taskFail = [pscustomobject]@{ name = "Fail hook"; post_script = "wrap-fail.ps1" }
    $threw = $false
    $result = $null
    try {
        $result = Invoke-TaskPostScriptIfPresent -Task $taskFail -BotRoot $wrapRoot `
            -ProductDir $productDir -Settings $settings -Model "balanced" -ProcessId "p1"
    } catch { $threw = $true }
    Assert-True -Name "Wrapper: failure does not throw" -Condition (-not $threw)
    Assert-True -Name "Wrapper: failure returns non-null string" -Condition ($null -ne $result -and $result -is [string])
    Assert-True -Name "Wrapper: failure message mentions post_script" `
        -Condition ($result -match "post_script failed")

} finally {
    Remove-Item -Path $wrapRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# INVOKE-POSTSCRIPTFAILUREESCALATION
# ═══════════════════════════════════════════════════════════════════
# When a Claude-executed task's post_script fails AFTER task_mark_done has
# moved the task JSON to done/, we escalate to needs-input/ with a
# pending_question rather than destroying the worktree. This regression guards
# that behaviour — see review item 2 / the "Path B broken" trace.

Write-Host "  INVOKE-POSTSCRIPTFAILUREESCALATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$escRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-esc-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
$escTasksDir = Join-Path $escRoot "workspace\tasks"
New-Item -ItemType Directory -Path (Join-Path $escTasksDir "done") -Force | Out-Null

try {
    # Seed a task file in done/ (simulating the state after task_mark_done has run)
    $taskId = "abcdef1234567890"
    $taskJson = @{
        id = $taskId
        name = "Esc test task"
        status = "done"
        completed_at = "2026-04-11T00:00:00Z"
    } | ConvertTo-Json -Depth 10
    $taskFilePath = Join-Path $escTasksDir "done\$taskId.json"
    $taskJson | Set-Content -Path $taskFilePath -Encoding UTF8

    $taskObj = [pscustomobject]@{ id = $taskId; name = "Esc test task" }
    $worktreePath = "C:\fake\worktree\path"

    $moved = Invoke-PostScriptFailureEscalation -Task $taskObj -TasksBaseDir $escTasksDir `
        -PostScriptError "post_script failed: exit 5" -WorktreePath $worktreePath

    Assert-True -Name "Escalation: returns true when task found in done/" -Condition $moved
    Assert-True -Name "Escalation: task removed from done/" -Condition (-not (Test-Path $taskFilePath))

    $needsInputFile = Join-Path $escTasksDir "needs-input\$taskId.json"
    Assert-PathExists -Name "Escalation: task now in needs-input/" -Path $needsInputFile

    if (Test-Path $needsInputFile) {
        $movedContent = Get-Content $needsInputFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "Escalation: status is needs-input" -Expected "needs-input" -Actual $movedContent.status
        Assert-True -Name "Escalation: pending_question present" `
            -Condition ($null -ne $movedContent.pending_question)
        Assert-Equal -Name "Escalation: pending_question.id" `
            -Expected "post-script-failure" -Actual $movedContent.pending_question.id
        Assert-True -Name "Escalation: context includes error message" `
            -Condition ($movedContent.pending_question.context -match "exit 5")
        Assert-True -Name "Escalation: context includes worktree path" `
            -Condition ($movedContent.pending_question.context -match [regex]::Escape($worktreePath))
        Assert-True -Name "Escalation: options present" `
            -Condition ($movedContent.pending_question.options.Count -ge 2)
    }

    # Task not in done/ → returns $false without throwing
    $missingTask = [pscustomobject]@{ id = "nonexistent-id"; name = "Missing" }
    $threw = $false
    $result = $null
    try {
        $result = Invoke-PostScriptFailureEscalation -Task $missingTask -TasksBaseDir $escTasksDir `
            -PostScriptError "whatever" -WorktreePath ""
    } catch { $threw = $true }
    Assert-True -Name "Escalation: missing task does not throw" -Condition (-not $threw)
    Assert-True -Name "Escalation: missing task returns false" -Condition ($result -eq $false)

    # Empty worktree path is accepted (e.g. if we ever call this from a non-worktree path)
    $taskId2 = "fedcba0987654321"
    @{ id = $taskId2; name = "No worktree"; status = "done" } | ConvertTo-Json -Depth 10 |
        Set-Content -Path (Join-Path $escTasksDir "done\$taskId2.json") -Encoding UTF8
    $taskObj2 = [pscustomobject]@{ id = $taskId2; name = "No worktree" }
    $moved2 = Invoke-PostScriptFailureEscalation -Task $taskObj2 -TasksBaseDir $escTasksDir `
        -PostScriptError "boom" -WorktreePath ""
    Assert-True -Name "Escalation: empty worktree path works" -Condition $moved2
    $niFile2 = Join-Path $escTasksDir "needs-input\$taskId2.json"
    if (Test-Path $niFile2) {
        $c2 = Get-Content $niFile2 -Raw | ConvertFrom-Json
        Assert-True -Name "Escalation: empty worktree path omits 'Worktree preserved'" `
            -Condition (-not ($c2.pending_question.context -match "Worktree preserved"))
    }

} finally {
    Remove-Item -Path $escRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# POST_SCRIPT WIRING (regression for andresharpe/dotbot#222)
# ═══════════════════════════════════════════════════════════════════
# Static check that both engines actually call into the shared helper.
# If anyone re-removes the wiring the task-runner would once again silently
# ignore post_script — these tests guard against that regression.

Write-Host "  POST_SCRIPT WIRING" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$workflowProcessPath = Join-Path $repoRoot "src/runtime/Scripts/Invoke-WorkflowProcess.ps1"

Assert-PathExists -Name "Invoke-WorkflowProcess.ps1 exists" -Path $workflowProcessPath

$workflowSrc = Get-Content $workflowProcessPath -Raw

Assert-True -Name "Invoke-WorkflowProcess imports Dotbot.Task" `
    -Condition ($workflowSrc -match 'Dotbot\.Task\.psd1')

$wrapperCallCount = ([regex]::Matches($workflowSrc, 'Invoke-TaskPostScriptIfPresent')).Count
Assert-True -Name "Invoke-WorkflowProcess calls wrapper in both branches (>=2 call sites)" `
    -Condition ($wrapperCallCount -ge 2)

# Ensure the Claude-branch post_script failure escalates the workflow-run task
# to needs-input rather than falling into generic failure cleanup (worktree
# destruction, failure-counter bump). Regression guard for the Path B bug traced
# during review.
Assert-True -Name "Invoke-WorkflowProcess tracks postScriptFailed flag" `
    -Condition ($workflowSrc -match '\$postScriptFailed\s*=\s*\$true')
Assert-True -Name "Invoke-WorkflowProcess has elseif (postScriptFailed) branch" `
    -Condition ($workflowSrc -match 'elseif\s*\(\s*\$postScriptFailed\s*\)')
Assert-True -Name "Invoke-WorkflowProcess escalates post_script failure in run task file" `
    -Condition ($workflowSrc -match 'Set-WorkflowTaskNeedsInput[\s\S]*postScriptFailureSource')

# Regression guards for paused-task handling. When the agent calls
# task_mark_needs_input, the orchestrator must NOT take the success path —
# Complete-TaskWorktree squash-merges and increments tasks_completed, both
# of which corrupt state for a paused task. See issue #382 for the
# symptom trace.
Assert-True -Name "Invoke-WorkflowProcess initialises taskParked=false" `
    -Condition ($workflowSrc -match '\$taskParked\s*=\s*\$false')
Assert-True -Name "Invoke-WorkflowProcess sets taskParked=true on needs-input" `
    -Condition ($workflowSrc -match '\$taskParked\s*=\s*\$true')
$parkedBranchMatch = [regex]::Match($workflowSrc, 'if\s*\(\s*\$taskParked\s*\)\s*\{(?<body>[\s\S]*?)\}\s*elseif\s*\(\s*\$taskSuccess\s*\)')
Assert-True -Name "Invoke-WorkflowProcess has if (taskParked) branch before merge" `
    -Condition $parkedBranchMatch.Success `
    -Message "Expected the parked branch to come before the success branch so merge is skipped for paused tasks"
$parkedBranchBody = if ($parkedBranchMatch.Success) { $parkedBranchMatch.Groups['body'].Value } else { '' }
Assert-True -Name "Paused branch does NOT call Complete-TaskWorktree" `
    -Condition ($parkedBranchBody -notmatch 'Complete-TaskWorktree') `
    -Message "Paused tasks must skip the squash-merge — Complete-TaskWorktree should not appear inside the if (taskParked) branch"
Assert-True -Name "Paused branch does NOT increment tasks_completed" `
    -Condition ($parkedBranchBody -notmatch '\$tasksProcessed\+\+') `
    -Message "tasks_completed must not be incremented for paused tasks"
Assert-True -Name "Paused branch emits 'Paused (needs-input)' heartbeat" `
    -Condition ($workflowSrc -match '"Paused\s*\(needs-input\):\s*\$\(\$task\.name\)"')

# Regression guard for merge-failure accounting. A completed execution can
# still fail during task branch integration; that path escalates to needs-input
# and must not be counted as a completed process task.
Assert-True -Name "Invoke-WorkflowProcess tracks mergeCompleted flag" `
    -Condition (($workflowSrc -match '\$mergeCompleted\s*=\s*\$true') -and ($workflowSrc -match '\$mergeCompleted\s*=\s*\$false'))
Assert-True -Name "Invoke-WorkflowProcess only increments tasks_completed after successful merge" `
    -Condition ($workflowSrc -match 'if\s*\(\s*\$mergeCompleted\s*\)\s*\{[\s\S]*?\$tasksProcessed\+\+') `
    -Message "tasks_completed must only increment inside the mergeCompleted success branch"
Assert-True -Name "Invoke-WorkflowProcess records merge failure heartbeat" `
    -Condition ($workflowSrc -match '"Merge failed:\s*\$\(\$task\.name\)"')

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TASK-RUNNER PARITY (PR-3a)
# ═══════════════════════════════════════════════════════════════════
# Regression guards for the four parity items the task-runner absorbed
# from the workflow execution engine: briefing-file injection, interview-summary
# injection, outputs validation, front_matter_docs. If any of these
# helpers gets removed, every shipped workflow.json silently regresses.

Write-Host "  TASK-RUNNER PARITY (briefing, interview-summary, outputs, front-matter)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Invoke-WorkflowProcess defines Get-WorkflowPromptContext helper" `
    -Condition ($workflowSrc -match 'function\s+Get-WorkflowPromptContext')
Assert-True -Name "Invoke-WorkflowProcess injects context into single-session prompt" `
    -Condition ($workflowSrc -match '\$execPromptContext\s*=\s*Get-WorkflowPromptContext')
Assert-True -Name "Get-WorkflowPromptContext reads briefing/ directory" `
    -Condition ($workflowSrc -match 'briefingDir\s*=\s*Join-Path\s+\$ProductDir\s+"briefing"')
Assert-True -Name "Get-WorkflowPromptContext reads interview-summary.md" `
    -Condition ($workflowSrc -match 'interviewSummaryPath\s*=\s*Join-Path\s+\$ProductDir\s+"interview-summary\.md"')

Assert-True -Name "Invoke-WorkflowProcess defines Test-TaskOutput helper" `
    -Condition ($workflowSrc -match 'function\s+Test-TaskOutput\b')
Assert-True -Name "Invoke-WorkflowProcess defines Add-TaskFrontMatter helper" `
    -Condition ($workflowSrc -match 'function\s+Add-TaskFrontMatter\b')

# Both task paths (non-prompt + prompt) must call these helpers — count >= 2.
# Match both direct (`Test-TaskOutput -Task`) and splatted (`Test-TaskOutput @args`)
# call styles so a future refactor that swaps one for the other doesn't trip
# this guard.
$outputCallCount = ([regex]::Matches($workflowSrc, 'Test-TaskOutput\s+(-Task|@\w)')).Count
Assert-True -Name "Test-TaskOutput called from both task paths (>=2 sites)" `
    -Condition ($outputCallCount -ge 2)
$frontMatterCallCount = ([regex]::Matches($workflowSrc, 'Add-TaskFrontMatter\s+(-Task|@\w)')).Count
Assert-True -Name "Add-TaskFrontMatter called from both task paths (>=2 sites)" `
    -Condition ($frontMatterCallCount -ge 2)
# Baseline capture must precede each Test-TaskOutput call site so the
# delta-vs-absolute logic actually runs (otherwise the legacy-engine
# absolute-count behaviour would silently re-emerge).
$baselineCallCount = ([regex]::Matches($workflowSrc, 'Get-TaskOutputBaseline\s+-Task')).Count
Assert-True -Name "Get-TaskOutputBaseline captured in both task paths (>=2 sites)" `
    -Condition ($baselineCallCount -ge 2)

Assert-True -Name "Test-TaskOutput supports legacy required_outputs alias" `
    -Condition ($workflowSrc -match "'required_outputs'")
Assert-True -Name "Test-TaskOutput supports outputs_dir + min_output_count" `
    -Condition (($workflowSrc -match 'outputs_dir') -and ($workflowSrc -match 'min_output_count'))
Assert-True -Name "Add-TaskFrontMatter sets generator to dotbot-task-runner" `
    -Condition ($workflowSrc -match 'dotbot-task-runner')
Assert-True -Name "Prompt task execution derives product dir from active worktree" `
    -Condition (($workflowSrc -match '\$executionBotRoot\s*=\s*if\s*\(\$worktreePath\)') -and
                ($workflowSrc -match '\$executionProductDir\s*=\s*Join-Path'))
Assert-True -Name "Prompt task execution loads workflow recipe prompts" `
    -Condition (($workflowSrc -match '\$taskTypeVal\s+-in\s+@\(''prompt'',\s*''prompt_template''\)') -and
                ($workflowSrc -match '\$task\.prompt'))
Assert-True -Name "Prompt task output checks use execution product dir" `
    -Condition (($workflowSrc -match 'ProductDir\s*=\s*\$executionProductDir') -and
                ($workflowSrc -match 'Get-TaskOutputBaseline\s+-Task\s+\$task\s+-BotRoot\s+\$executionBotRoot'))
Assert-True -Name "Prompt task execution preflights dotbot MCP before harness launch" `
    -Condition (($workflowSrc -match 'Test-DotbotMcpReadiness\s+-WorktreePath\s+\$worktreePath') -and
                ($workflowSrc.IndexOf('Test-DotbotMcpReadiness -WorktreePath $worktreePath') -lt $workflowSrc.IndexOf('Invoke-HarnessStream @streamArgs')))
Assert-True -Name "Workflow runner no longer auto-commits an empty repo" `
    -Condition (-not ($workflowSrc -match 'Created initial git commit|chore: initialize dotbot'))
Assert-True -Name "Workflow runner allows zero-commit git repos" `
    -Condition (-not ($workflowSrc -match 'at least one commit|commit first'))

$claudeAdapterSrc = Get-Content (Join-Path $repoRoot 'src/runtime/Modules/Dotbot.Harness/Adapters/ClaudeCodeAdapter.ps1') -Raw
Assert-True -Name "Claude adapter passes worktree MCP config explicitly" `
    -Condition (($claudeAdapterSrc -match '--mcp-config') -and ($claudeAdapterSrc -match '\.mcp\.json'))

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TASK-RUNNER INTERVIEW TASK TYPE (PR-3b, #220)
# ═══════════════════════════════════════════════════════════════════
# The interview task type is a shipped executor. Regression guard against
# moving it back into the runner's dispatch switch.

Write-Host "  TASK-RUNNER INTERVIEW TASK TYPE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Invoke-WorkflowProcess imports Dotbot.Task (Invoke-InterviewLoop lives there)" `
    -Condition ($workflowSrc -match 'Dotbot\.Task\.psd1')
$interviewExecutorSrc = Get-Content (Join-Path $repoRoot 'src/runtime/Plugins/Executors/interview/script.ps1') -Raw
Assert-True -Name "Invoke-WorkflowProcess delegates to Dotbot.Executor" `
    -Condition ($workflowSrc -match 'Invoke-TaskExecutor')
Assert-True -Name "Invoke-WorkflowProcess has no 'interview' dispatch switch case" `
    -Condition ($workflowSrc -notmatch "'interview'\s*\{")
Assert-True -Name "Interview executor calls Invoke-InterviewLoop" `
    -Condition ($interviewExecutorSrc -match 'Invoke-InterviewLoop')
Assert-True -Name "Interview executor resolves user prompt from workflow-launch-prompt.txt" `
    -Condition ($interviewExecutorSrc -match 'workflow-launch-prompt\.txt')

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TASK-RUNNER CLARIFICATION-QUESTIONS HITL LOOP (PR-3c, #221)
# ═══════════════════════════════════════════════════════════════════
# The task-runner now detects clarification-questions.json after a prompt
# task and pauses the process for human input, then runs adjust-after-answers.

Write-Host "  TASK-RUNNER CLARIFICATION HITL LOOP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Invoke-WorkflowProcess defines Invoke-TaskClarificationLoopIfPresent" `
    -Condition ($workflowSrc -match 'function\s+Invoke-TaskClarificationLoopIfPresent\b')
Assert-True -Name "Clarification loop checks clarification-questions.json" `
    -Condition ($workflowSrc -match 'clarification-questions\.json')
Assert-True -Name "Clarification loop polls for clarification-answers.json" `
    -Condition ($workflowSrc -match 'clarification-answers\.json')
Assert-True -Name "Clarification loop sets process status to needs-input" `
    -Condition ($workflowSrc -match "ProcessData\.status\s*=\s*'needs-input'")
Assert-True -Name "Clarification loop runs adjust-after-answers prompt" `
    -Condition ($workflowSrc -match 'adjust-after-answers\.md')
Assert-True -Name "Clarification loop appends to interview-summary.md" `
    -Condition ($workflowSrc -match 'interview-summary\.md.*Clarification Log' -or $workflowSrc -match 'Clarification Log')
Assert-True -Name "Clarification loop is wired into prompt-task path" `
    -Condition ($workflowSrc -match 'Invoke-TaskClarificationLoopIfPresent\s+-Task')
Assert-True -Name "Clarification loop respects stop signal" `
    -Condition ($workflowSrc -match 'Test-ProcessStopSignal[\s\S]{0,400}clarification')

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW FRICTION FIXES (batch 1)
# ═══════════════════════════════════════════════════════════════════
# Regressions guarding the four fixes that came out of analysing a real
# start-from-prompt activity.jsonl run in a downstream harness.
# See the PR description in fix/workflow-friction-batch-1 for context.

Write-Host "  WORKFLOW FRICTION FIXES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# ── Fix #1: Dotbot.Workflow must export Test-ManifestCondition so it stays
# visible across module-scope boundaries (the pattern server.ps1 and
# task-get-next/script.ps1 use). ManifestCondition was a separate module pre-
# and required -Global on its import; after the merge it's part of Dotbot.Workflow.
$workflowManifestPath = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psm1"
$workflowManifestSrc = Get-Content $workflowManifestPath -Raw

Assert-True -Name "Fix#1: Dotbot.Workflow defines Test-ManifestCondition inline" `
    -Condition ($workflowManifestSrc -match 'function\s+Test-ManifestCondition\b')

# Regression: import Dotbot.Workflow inside a nested scriptblock and verify
# Test-ManifestCondition remains visible *after that child scope exits*. The
# module is consumed by HTTP route handlers (server.ps1) and MCP tool scripts
# whose imports run inside function/scriptblock scope.
Remove-Module Dotbot.Workflow -Force -ErrorAction SilentlyContinue
$nestedProbe = $false
try {
    & {
        Import-Module $workflowManifestPath -Force -DisableNameChecking
    }
    $nestedProbe = (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue) -ne $null
} finally {
    Remove-Module Dotbot.Workflow -Force -ErrorAction SilentlyContinue
}
Assert-True -Name "Fix#1: Test-ManifestCondition visible after nested import of Dotbot.Workflow" `
    -Condition $nestedProbe

# Fix #2 (legacy engine auto-push) was removed in PR-3 along with the
# legacy engine. Task-runner's squash-merge in Complete-TaskWorktree handles
# pushing for completed tasks; phase-level auto-push no longer applies.

# ── Fix #3: workflow prompt templates must instruct agents to retry the same
# select: query rather than broadening when the MCP server is still warming up.
$promptFiles = @(
    (Join-Path $repoRoot "content\workflows\start-from-prompt\recipes\prompts\03b-expand-task-group.md"),
    (Join-Path $repoRoot "content\workflows\start-from-prompt\recipes\prompts\01b-generate-decisions.md"),
    (Join-Path $repoRoot "content/prompts/98-analyse-task.md")
)
foreach ($pf in $promptFiles) {
    $relName = Split-Path $pf -Leaf
    Assert-PathExists -Name "Fix#3: $relName exists" -Path $pf
    $promptSrc = Get-Content $pf -Raw
    Assert-True -Name "Fix#3: $relName forbids broadening ToolSearch queries" `
        -Condition ($promptSrc -match 'do\s+\*\*NOT\*\*\s+broaden')
    Assert-True -Name "Fix#3: $relName instructs retry of same select: query" `
        -Condition ($promptSrc -match 'retry\s+the\s+\*\*exact\s+same\*\*\s+`?select:')
}

# ── Fix #4: 01b-generate-decisions.md must mark interview-summary.md as an
# optional read so the new_project workflow path (show_interview: false)
# doesn't error on a missing file.
$decisionsPromptPath = Join-Path $repoRoot "content\workflows\start-from-prompt\recipes\prompts\01b-generate-decisions.md"
$decisionsPromptSrc = Get-Content $decisionsPromptPath -Raw
Assert-True -Name "Fix#4: 01b-generate-decisions.md marks interview-summary.md as optional" `
    -Condition ($decisionsPromptSrc -match '(?s)interview\s+summary\s+is\s+\*\*optional\*\*.*?interview-summary\.md')
Assert-True -Name "Fix#4: 01b-generate-decisions.md still reads mission/tech-stack/entity-model unconditionally" `
    -Condition (($decisionsPromptSrc -match 'mission\.md') -and ($decisionsPromptSrc -match 'tech-stack\.md') -and ($decisionsPromptSrc -match 'entity-model\.md'))

# ── Batch 2, Fix A: 99-autonomous-task.md must teach agents branch-conditional
# push semantics so tasks that run on shared branches (main/master) are
# pushed immediately instead of leaving the agent stuck on the
# 02-git-pushed.ps1 gate at task_mark_done time.
$autonomousTaskPrompts = @(
    (Join-Path $repoRoot "content/prompts/99-autonomous-task.md"),
    (Join-Path $repoRoot "content/workflows/start-from-jira/recipes/prompts/99-autonomous-task.md")
)
foreach ($pf in $autonomousTaskPrompts) {
    $relName = Split-Path $pf -Leaf
    # Label the prompt by its top-level source — "core" for the framework copy,
    # the workflow name for workflow-scoped overrides.
    $parentDir = if ($pf -match '[/\\]core[/\\]prompts[/\\]') {
        'core'
    } else {
        Split-Path (Split-Path (Split-Path (Split-Path $pf -Parent) -Parent) -Parent) -Leaf
    }
    Assert-PathExists -Name "Fix#A: $parentDir/$relName exists" -Path $pf
    $src = Get-Content $pf -Raw
    Assert-True -Name "Fix#A: $parentDir/$relName assumes a task worktree" `
        -Condition ($src -match 'task\s+worktree')
    Assert-True -Name "Fix#A: $parentDir/$relName tells agents not to push" `
        -Condition ($src -match 'do\s+not\s+push')
    Assert-True -Name "Fix#A: $parentDir/$relName no longer has shared-branch fallback instructions" `
        -Condition (-not ($src -match 'shared\s+branch|push\s+immediately|02-git-pushed\.ps1'))
    Assert-True -Name "Fix#A: $parentDir/$relName no longer hardcodes old bold worktree assertion" `
        -Condition (-not ($src -match 'You are working in a \*\*git worktree\*\* on branch'))
}

# ── Batch 2, Fix B: 03a-plan-task-groups.md must include task-level rigor
# (schema, acceptance-criteria quality bar, effort sizing, dependency chain)
# that 03b-expand-task-group.md inherits during expansion.
$planTaskGroupsPath = Join-Path $repoRoot "content\workflows\start-from-prompt\recipes\prompts\03a-plan-task-groups.md"
Assert-PathExists -Name "Fix#B: 03a-plan-task-groups.md exists" -Path $planTaskGroupsPath
$planTaskGroupsSrc = Get-Content $planTaskGroupsPath -Raw

Assert-True -Name "Fix#B: 03a has Task Schema Reference section" `
    -Condition ($planTaskGroupsSrc -match '##\s+Task Schema Reference')
Assert-True -Name "Fix#B: 03a requires per-task acceptance_criteria field" `
    -Condition ($planTaskGroupsSrc -match '`acceptance_criteria`.*testable')
Assert-True -Name "Fix#B: 03a requires human_hours / ai_hours estimates" `
    -Condition (($planTaskGroupsSrc -match '`human_hours`') -and ($planTaskGroupsSrc -match '`ai_hours`'))
Assert-True -Name "Fix#B: 03a has Good Task Acceptance Criteria section" `
    -Condition ($planTaskGroupsSrc -match '##\s+Good Task Acceptance Criteria')
Assert-True -Name "Fix#B: 03a has Effort Sizing section" `
    -Condition ($planTaskGroupsSrc -match '##\s+Effort Sizing')
Assert-True -Name "Fix#B: 03a Effort Sizing has XS through XL rows" `
    -Condition (($planTaskGroupsSrc -match '`XS`') -and ($planTaskGroupsSrc -match '`XL`'))
Assert-True -Name "Fix#B: 03a Step 3 dependency chain mentions infra/entities/features" `
    -Condition ($planTaskGroupsSrc -match '(?s)Infrastructure.*entities.*[Ff]eature.*jobs')
Assert-True -Name "Fix#B: 03a anti-patterns forbid effort-based buckets" `
    -Condition ($planTaskGroupsSrc -match '[Ee]ffort-based\s+buckets')

# ── Batch 2, Fix B cross-link: 03b-expand-task-group.md must inherit from 03a.
$expandTaskGroupPath = Join-Path $repoRoot "content\workflows\start-from-prompt\recipes\prompts\03b-expand-task-group.md"
$expandTaskGroupSrc = Get-Content $expandTaskGroupPath -Raw
Assert-True -Name "Fix#B: 03b cross-links to 03a for schema/criteria/sizing" `
    -Condition ($expandTaskGroupSrc -match 'Inherits\s+from\s+03a-plan-task-groups\.md')
Assert-True -Name "Fix#B: 03b tells agent not to relax constraints during expansion" `
    -Condition ($expandTaskGroupSrc -match 'do\s+not\s+relax\s+them\s+during\s+expansion')

# ── Batch 2, Fix C: 98-analyse-task.md must guard mission/tech-stack/entity-model
# reads against the current task's outputs list, so tasks that produce those
# files (e.g. workflow Product Documents) do not error during pre-flight
# analysis trying to read files they are supposed to create.
$analyseTaskPath = Join-Path $repoRoot "content/prompts/98-analyse-task.md"
Assert-PathExists -Name "Fix#C: 98-analyse-task.md exists" -Path $analyseTaskPath
$analyseTaskSrc = Get-Content $analyseTaskPath -Raw
Assert-True -Name "Fix#C: 98-analyse-task.md has skip-if-produced guard in Phase 2" `
    -Condition ($analyseTaskSrc -match '(?s)Phase\s+2:\s+Entity\s+Detection.*?Skip-if-produced\s+guard')
Assert-True -Name "Fix#C: 98-analyse-task.md has skip-if-produced guard in Phase 6" `
    -Condition ($analyseTaskSrc -match '(?s)Phase\s+6:\s+Product\s+Context\s+Extraction.*?Skip-if-produced\s+guard')
Assert-True -Name "Fix#C: 98-analyse-task.md entity-model read is marked skip-if-outputs" `
    -Condition ($analyseTaskSrc -match 'Read\s+entity\s+model[^\r\n]*skip\s+if\s+in\s+task\s+`outputs`')
Assert-True -Name "Fix#C: 98-analyse-task.md mission read is marked skip-if-outputs" `
    -Condition ($analyseTaskSrc -match 'Read\s+mission[^\r\n]*skip\s+if\s+in\s+task\s+`outputs`')
Assert-True -Name "Fix#C: 98-analyse-task.md refers to task outputs list for the guard" `
    -Condition ($analyseTaskSrc -match "task's\s+``outputs``\s+list")

# ── #365: 98-analyse-task.md must not probe .bot/recipes/standards/global with
# a Glob, and 99-autonomous-task.md must not list it as a context-file source.
# The prompt now relies on {{APPLICABLE_STANDARDS}} plus the task's
# `applicable_standards` list. Both checks must hold even if a future edit
# reorders the Glob keys or splits the call across lines.
Assert-True -Name "#365: 98-analyse-task.md no longer issues a Glob over .bot/recipes/standards/global" `
    -Condition (-not ($analyseTaskSrc -match '(?s)Glob\([^)]*\.bot/recipes/standards/global'))
Assert-True -Name "#365: 98-analyse-task.md tells the agent not to probe .bot/recipes/standards/global" `
    -Condition ($analyseTaskSrc -match 'Do\s+not\s+probe\s+`\.bot/recipes/standards/global/`')

$execPromptSrc = Get-Content (Join-Path $repoRoot "content/prompts/99-autonomous-task.md") -Raw
Assert-True -Name "#365: 99-autonomous-task.md no longer cites .bot/recipes/standards/global/*.md as a context file" `
    -Condition (-not ($execPromptSrc -match '\.bot/recipes/standards/global/\*\.md'))

# Runtime fallback must not push agents back toward the directory the prompts
# now tell them to avoid. PromptBuilder.psm1's APPLICABLE_STANDARDS fallback
# previously said "use global standards from .bot/recipes/standards/global/".
$promptBuilderSrc = Get-Content (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psm1") -Raw
Assert-True -Name "#365: prompt-builder APPLICABLE_STANDARDS fallback does not mention recipes/standards/global" `
    -Condition (-not ($promptBuilderSrc -match '(?s)applicableStandards\s*=\s*"[^"]*\.bot/recipes/standards/global'))

# ── Batch 2, Fix E: 03a category_hint field-reference row must list the full
# six-value enum and forbid inventing new categories like `frontend`.
Assert-True -Name "Fix#E: 03a category_hint row lists ui-ux enum value" `
    -Condition ($planTaskGroupsSrc -match '(?s)\|\s+`category_hint`.*?`ui-ux`')
Assert-True -Name "Fix#E: 03a category_hint row lists bugfix enum value" `
    -Condition ($planTaskGroupsSrc -match '(?s)\|\s+`category_hint`.*?`bugfix`')
Assert-True -Name "Fix#E: 03a category_hint row forbids inventing new categories" `
    -Condition ($planTaskGroupsSrc -match '(?s)`category_hint`.*?Do\s+NOT\s+invent\s+new\s+categories')
Assert-True -Name "Fix#E: 03a category_hint row cites task_create_bulk validator" `
    -Condition ($planTaskGroupsSrc -match '(?s)`category_hint`.*?`task_create_bulk`\s+validator')

# ── Batch 3, Fix F: 03b-expand-task-group.md must enforce the per-task
# quality bar, leave group sizing to 03a (Fix#H owns the fan-out cap),
# allow only the closed category enum, align dependency naming with what
# the task_create_bulk validator actually accepts, and treat an empty
# {{GROUP_APPLICABLE_DECISIONS}} via a decision_list fallback rather than
# silent zero-ADR expansion.
Assert-True -Name "Fix#F: 03b leads with per-task quality bar (logical, context-friendly, executable, testable)" `
    -Condition ($expandTaskGroupSrc -match 'logical,\s+context-friendly,\s+executable,\s+testable\s+unit')
Assert-True -Name "Fix#F: 03b states group sizing is 03a's responsibility" `
    -Condition ($expandTaskGroupSrc -match "Group\s+sizing\s+is\s+03a's\s+responsibility")
Assert-True -Name "Fix#F: 03b does not police group size or emit group_size_warning" `
    -Condition (-not ($expandTaskGroupSrc -match 'group_size_warning'))
Assert-True -Name "Fix#F: 03b lists all six valid category enum values" `
    -Condition (($expandTaskGroupSrc -match '`infrastructure`') -and `
                ($expandTaskGroupSrc -match '`core`') -and `
                ($expandTaskGroupSrc -match '`feature`') -and `
                ($expandTaskGroupSrc -match '`enhancement`') -and `
                ($expandTaskGroupSrc -match '`ui-ux`') -and `
                ($expandTaskGroupSrc -match '`bugfix`'))
Assert-True -Name "Fix#F: 03b forbids inventing categories like testing or frontend" `
    -Condition ($expandTaskGroupSrc -match 'Do\s+\*\*NOT\*\*\s+invent\s+categories.*?`testing`')
Assert-True -Name "Fix#F: 03b cites task_create_bulk validator for category enum" `
    -Condition ($expandTaskGroupSrc -match '(?s)closed\s+enum.*?task_create_bulk.*?validator')
Assert-True -Name "Fix#F: 03b documents the four resolution strategies the validator accepts" `
    -Condition (($expandTaskGroupSrc -match 'exact\s+`id`\s+match') -and `
                ($expandTaskGroupSrc -match 'exact\s+`name`\s+match') -and `
                ($expandTaskGroupSrc -match 'slug\s+match') -and `
                ($expandTaskGroupSrc -match 'fuzzy\s+slug\s+substring\s+match'))
Assert-True -Name "Fix#F: 03b recommends id for cross-group dependencies" `
    -Condition ($expandTaskGroupSrc -match '(?s)Cross-group\s+dependencies.*?task\s+\*\*`id`\*\*')
Assert-True -Name "Fix#F: 03b recommends exact name for intra-batch dependencies" `
    -Condition ($expandTaskGroupSrc -match '(?s)Intra-batch\s+dependencies.*?exact\s+`name`')
Assert-True -Name "Fix#F: 03b marks slug/fuzzy as fallback, not contract" `
    -Condition ($expandTaskGroupSrc -match 'fallbacks?,\s+not\s+a\s+contract')
Assert-True -Name "Fix#F: 03b has decision_list fallback when GROUP_APPLICABLE_DECISIONS has no dec- IDs" `
    -Condition ($expandTaskGroupSrc -match '(?s)contains\s+no\s+`dec-`\s+IDs.*?decision_list')

# ── Batch 3, Fix G: Expand-TaskGroups.ps1 must substitute
# {{GROUP_APPLICABLE_DECISIONS}} from each group's applicable_decisions field
# so the prompt actually receives the ADR ID list 03a recorded.
$expandScriptPath = Join-Path $repoRoot "src" "runtime" "Scripts" "Expand-TaskGroups.ps1"
Assert-PathExists -Name "Fix#G: Expand-TaskGroups.ps1 exists" -Path $expandScriptPath
$expandScriptSrc = Get-Content $expandScriptPath -Raw
Assert-True -Name "Fix#G: Expand-TaskGroups.ps1 substitutes GROUP_APPLICABLE_DECISIONS" `
    -Condition ($expandScriptSrc -match "-replace\s+'[^']*GROUP_APPLICABLE_DECISIONS")
Assert-True -Name "Fix#G: Expand-TaskGroups.ps1 reads group.applicable_decisions" `
    -Condition ($expandScriptSrc -match '\$group\.applicable_decisions')
Assert-True -Name "Fix#G: Expand-TaskGroups.ps1 emits '(none)' when applicable_decisions is empty" `
    -Condition ($expandScriptSrc -match '"\(none\)"')

# ── Batch 3, Fix H: 03a-plan-task-groups.md owns group sizing — must validate
# expansion fan-out and split groups whose scope would expand to 12+ tasks
# at 03b's per-task quality bar, before writing task-groups.json.
Assert-True -Name "Fix#H: 03a has Step 2.5 Validate Expansion Fan-Out" `
    -Condition ($planTaskGroupsSrc -match '###\s+Step\s+2\.5:\s+Validate\s+Expansion\s+Fan-Out')
Assert-True -Name "Fix#H: 03a tells the planner group sizing is its responsibility" `
    -Condition ($planTaskGroupsSrc -match 'Group\s+sizing\s+is\s+your\s+responsibility,\s+not\s+03b')
Assert-True -Name "Fix#H: 03a forces a split when a group would expand to 12+ tasks" `
    -Condition ($planTaskGroupsSrc -match '(?s)12\s+or\s+more\s+well-sized\s+tasks.*?split\s+it\s+now')
Assert-True -Name "Fix#H: 03a tightens estimated_task_count guidance to 3-10 healthy range" `
    -Condition ($planTaskGroupsSrc -match '(?s)`estimated_task_count`.*?(?:3-10|range\s+is\s+\*\*3-10\*\*)')
Assert-True -Name "Fix#H: 03a anti-patterns forbid kitchen-sink groups" `
    -Condition ($planTaskGroupsSrc -match '[Kk]itchen-sink\s+groups')
Assert-True -Name "Fix#H: 03a Step 2.5 surfaces the fan-out heuristic table" `
    -Condition ($planTaskGroupsSrc -match '(?s)Step\s+2\.5.*?Scope\s+shape.*?per-task\s+expansion')
Assert-True -Name "Fix#H: 03a example task-groups.json includes applicable_decisions" `
    -Condition ($planTaskGroupsSrc -match '"applicable_decisions":\s*\[')
Assert-True -Name "Fix#H: 03a Field Reference declares applicable_decisions as a required field" `
    -Condition ($planTaskGroupsSrc -match '\|\s+`applicable_decisions`\s+\|\s+Yes\s+\|')

# ── #364: Both core prompts must warn that the Bash tool runs Bash, not
# PowerShell. Agents picked up PowerShell's $obj.property syntax from the
# project's PowerShell-heavy code and got `extglob.project_name: command not
# found` errors when piping JSON through Bash.
$bashWarningPrompts = @(
    (Join-Path $repoRoot "content/prompts/99-autonomous-task.md"),
    (Join-Path $repoRoot "content/prompts/98-analyse-task.md")
)
foreach ($pf in $bashWarningPrompts) {
    $relName = Split-Path $pf -Leaf
    Assert-PathExists -Name "#364: $relName exists" -Path $pf
    $src = Get-Content $pf -Raw
    Assert-True -Name "#364: $relName warns the Bash tool runs Bash, not PowerShell" `
        -Condition ($src -match 'Bash\s+tool\s+runs\s+Bash,\s+not\s+PowerShell')
    Assert-True -Name "#364: $relName names `$obj.property as a forbidden idiom" `
        -Condition ($src -match '\$obj\.property')
    Assert-True -Name "#364: $relName tells the agent to use pwsh -Command for PowerShell semantics" `
        -Condition ($src -match 'pwsh\s+-Command')
}

Write-Host ""

# The Fix#1 nested-import test unloads Dotbot.Workflow in a finally; re-import
# before the tests so Test-CanStartRun / Test-GitReadyForWorktree are in
# scope. -Force handles the case where another test has reloaded the module.
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

# ═══════════════════════════════════════════════════════════════════
# Test-CanStartRun (concurrency rule truth table)
# ═══════════════════════════════════════════════════════════════════

Write-Host " Test-CanStartRun (truth table)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Row 1: first run = OK (no active runs)
$r = Test-CanStartRun -NewRun @{ workflow_name = 'start-from-prompt' } -ActiveRuns @()
Assert-True -Name "no active runs -> ok" -Condition $r.ok

# Row 2: different workflow can run concurrently
$r = Test-CanStartRun -NewRun @{ workflow_name = 'beta' } -ActiveRuns @(
    @{ id = 'wr_AAAA1111'; status = 'running'; workflow_name = 'alpha' }
)
Assert-True -Name "different running workflow -> ok" -Condition $r.ok

# Row 3: same workflow name is blocked
$r = Test-CanStartRun -NewRun @{ workflow_name = 'start-from-prompt' } -ActiveRuns @(
    @{ id = 'wr_JJJJ0000'; status = 'running'; workflow_name = 'start-from-prompt' }
)
Assert-True -Name "same workflow blocks concurrent run -> not ok" `
    -Condition (-not $r.ok)
Assert-Equal -Name "same workflow conflict reason" `
    -Expected 'same_workflow_conflict' -Actual $r.reason
Assert-Equal -Name "same workflow conflict names blocking run" `
    -Expected 'wr_JJJJ0000' -Actual $r.blocking_run_id

# Edge: completed / cancelled active runs are ignored
$r = Test-CanStartRun -NewRun @{ workflow_name = 'start-from-prompt' } -ActiveRuns @(
    @{ id = 'wr_EEEE5555'; status = 'done'; workflow_name = 'start-from-prompt' }
    @{ id = 'wr_FFFF6666'; status = 'failed'; workflow_name = 'start-from-prompt' }
    @{ id = 'wr_GGGG7777'; status = 'cancelled'; workflow_name = 'start-from-prompt' }
)
Assert-True -Name "terminal-state runs do not block" -Condition $r.ok

# Edge: PSCustomObject inputs work the same as hashtables
$psNew = [pscustomobject]@{ workflow_name = 'demo' }
$psActive = @([pscustomobject]@{ id = 'wr_IIII9999'; status = 'running'; workflow_name = 'demo' })
$r = Test-CanStartRun -NewRun $psNew -ActiveRuns $psActive
Assert-True -Name "rule handles PSCustomObject inputs" `
    -Condition ((-not $r.ok) -and ($r.blocking_run_id -eq 'wr_IIII9999'))

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# Test-GitReadyForWorktree
# ═══════════════════════════════════════════════════════════════════

Write-Host " Test-GitReadyForWorktree" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$gitTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-gitready-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $gitTestRoot -Force | Out-Null

try {
    # Case 1: empty directory (no .git) -> refusal with reason no_git
    $emptyDir = Join-Path $gitTestRoot "empty"
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    $r = Test-GitReadyForWorktree -ProjectRoot $emptyDir
    Assert-True -Name "empty dir -> not ok" -Condition (-not $r.ok)
    Assert-Equal -Name "empty dir reason is no_git" -Expected 'no_git' -Actual $r.reason
    Assert-True -Name "empty dir message explains worktree precondition" `
        -Condition ($r.message -match "Workflow runs require a git repo") `
        -Message "Message: $($r.message)"

    # Case 2: .git directory but no commits -> ok; orphan worktrees handle the first run.
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCommand) {
        $zeroCommitDir = Join-Path $gitTestRoot "zero-commits"
        New-Item -ItemType Directory -Path $zeroCommitDir -Force | Out-Null
        & git -C $zeroCommitDir init --quiet 2>&1 | Out-Null
        $r = Test-GitReadyForWorktree -ProjectRoot $zeroCommitDir
        Assert-True -Name ".git without commits -> ok" -Condition $r.ok
        & git -C $zeroCommitDir rev-parse --verify HEAD 2>$null | Out-Null
        Assert-True -Name "git-ready check does not create an initial commit" -Condition ($LASTEXITCODE -ne 0)

        # Case 3: .git with one commit -> ok
        $okDir = Join-Path $gitTestRoot "with-commit"
        New-Item -ItemType Directory -Path $okDir -Force | Out-Null
        & git -C $okDir init --quiet 2>&1 | Out-Null
        # Configure committer so commit doesn't fail on CI runners that lack identity.
        & git -C $okDir config user.email "tests@example.com" 2>&1 | Out-Null
        & git -C $okDir config user.name  "dotbot-tests"      2>&1 | Out-Null
        & git -C $okDir commit --allow-empty --quiet -m "initial" 2>&1 | Out-Null
        $r = Test-GitReadyForWorktree -ProjectRoot $okDir
        Assert-True -Name ".git with one commit -> ok" -Condition $r.ok `
            -Message "Result: $($r | ConvertTo-Json -Compress)"
    } else {
        Write-TestResult -Name "git-ready tests need git on PATH" -Status Skip `
            -Message "git command not found"
    }
} finally {
    if (Test-Path $gitTestRoot) { Remove-Item -Path $gitTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# workflow manifest removed isolation fields + skip_worktree lint
# ═══════════════════════════════════════════════════════════════════

Write-Host "  manifest worktree lint" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if ($true) {
    $isoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-worktree-lint-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    try {
        # Manifest with removed top-level isolated field -> lint error
        $isoTrueDir = Join-Path $isoRoot "removed-isolated"
        New-Item -ItemType Directory -Path $isoTrueDir -Force | Out-Null
        @'
{
  "name": "removed-isolated",
  "version": "1.0",
  "isolated": true,
  "tasks": [
    {
      "name": "Do A Thing",
      "type": "prompt"
    }
  ]
}
'@ | Set-Content (Join-Path $isoTrueDir "workflow.json") -Encoding UTF8
        $m = Read-WorkflowManifest -WorkflowDir $isoTrueDir
        $errors = Test-WorkflowManifestSchema -Manifest $m -WorkflowName 'removed-isolated'
        Assert-True -Name "top-level isolated raises lint error" `
            -Condition ((@($errors) -join "`n") -match "removed field 'isolated'")

        # Manifest with no isolated field -> no default or property is added
        $isoDefaultDir = Join-Path $isoRoot "no-isolated"
        New-Item -ItemType Directory -Path $isoDefaultDir -Force | Out-Null
        @'
{
  "name": "no-isolated",
  "version": "1.0",
  "tasks": [
    {
      "name": "Do A Thing",
      "type": "prompt"
    }
  ]
}
'@ | Set-Content (Join-Path $isoDefaultDir "workflow.json") -Encoding UTF8
        $m = Read-WorkflowManifest -WorkflowDir $isoDefaultDir
        Assert-True -Name "missing isolated does not add a manifest field" `
            -Condition (-not $m.Contains('isolated'))

        # Manifest with per-task skip_worktree -> lint error
        $lintDir = Join-Path $isoRoot "lint-skipwt"
        New-Item -ItemType Directory -Path $lintDir -Force | Out-Null
        @'
{
  "name": "lint-skipwt",
  "version": "1.0",
  "tasks": [
    {
      "name": "Naughty Task",
      "type": "prompt",
      "skip_worktree": true
    }
  ]
}
'@ | Set-Content (Join-Path $lintDir "workflow.json") -Encoding UTF8
        $m = Read-WorkflowManifest -WorkflowDir $lintDir
        $errors = Test-WorkflowManifestSchema -Manifest $m -WorkflowName 'lint-skipwt'
        Assert-True -Name "per-task skip_worktree raises lint error" `
            -Condition (@($errors).Count -gt 0)
        $errText = @($errors) -join "`n"
        Assert-True -Name "lint error names the offending task" `
            -Condition ($errText -match 'Naughty Task')
        Assert-True -Name "lint error explains mandatory worktrees" `
            -Condition ($errText -match 'always execute in git worktrees' -and $errText -match "Remove 'skip_worktree'")

        # Manifest without removed fields -> no worktree-related lint errors
        $cleanDir = Join-Path $isoRoot "clean"
        New-Item -ItemType Directory -Path $cleanDir -Force | Out-Null
        @'
{
  "name": "clean",
  "version": "1.0",
  "tasks": [
    {
      "name": "Good Task",
      "type": "prompt"
    }
  ]
}
'@ | Set-Content (Join-Path $cleanDir "workflow.json") -Encoding UTF8
        $m = Read-WorkflowManifest -WorkflowDir $cleanDir
        $errors = Test-WorkflowManifestSchema -Manifest $m -WorkflowName 'clean'
        Assert-True -Name "clean manifest has no removed-field lint error" `
            -Condition (-not (@($errors) -join "`n" -match 'skip_worktree|isolated'))
    } finally {
        if (Test-Path $isoRoot) { Remove-Item -Path $isoRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# Workflow registry tier resolution
# ═══════════════════════════════════════════════════════════════════

Write-Host " Find-Workflow + Discover-Workflows tier resolution" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if ($true) {
    # Build a fake project AND a fake DOTBOT_HOME. Project workflows live
    # under <botRoot>/content/workflows/ (new project tier); framework
    # workflows live under <fakeDotbotHome>/content/workflows/. Point
    # $env:DOTBOT_HOME at the fake framework so Get-DotbotInstallPath
    # routes there for the duration of these tests.
    $prd13ProjectRoot   = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-prd13-proj-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    $prd13FrameworkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-prd13-fw-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    $botRoot       = Join-Path $prd13ProjectRoot ".bot"
    $projectTier   = Join-Path $botRoot "content/workflows"
    $frameworkTier = Join-Path $prd13FrameworkRoot "content/workflows"

    function New-PRD13Workflow {
        param([string]$Dir, [string]$Name, [string]$Marker)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        @"
{
  "name": "$Name",
  "version": "1.0",
  "description": "$Marker"
}
"@ | Set-Content (Join-Path $Dir "workflow.json") -Encoding UTF8
    }

    $savedDotbotHomePRD13 = $env:DOTBOT_HOME
    try {
        $env:DOTBOT_HOME = $prd13FrameworkRoot

        # Framework-only workflow
        New-PRD13Workflow -Dir (Join-Path $frameworkTier "framework-only") -Name "framework-only" -Marker "framework-only-FW"
        # Project-only workflow
        New-PRD13Workflow -Dir (Join-Path $projectTier   "project-only")   -Name "project-only"   -Marker "project-only-PR"
        # Same-name in both tiers (project should win)
        New-PRD13Workflow -Dir (Join-Path $frameworkTier "shared-name") -Name "shared-name" -Marker "shared-FW"
        New-PRD13Workflow -Dir (Join-Path $projectTier   "shared-name") -Name "shared-name" -Marker "shared-PR"

        # ---- Find-Workflow ----

        # 1) Framework-only hit
        $r = Find-Workflow -BotRoot $botRoot -Name "framework-only"
        Assert-True -Name "framework-only resolves" -Condition ($r.ok)
        Assert-Equal -Name "framework-only source" -Expected "framework" -Actual $r.source
        Assert-True -Name "framework-only path is under DOTBOT_HOME" `
            -Condition ($r.path -like "$prd13FrameworkRoot*")

        # 2) Project-only hit
        $r = Find-Workflow -BotRoot $botRoot -Name "project-only"
        Assert-True -Name "project-only resolves" -Condition ($r.ok)
        Assert-Equal -Name "project-only source" -Expected "project" -Actual $r.source
        Assert-True -Name "project-only path is under <botRoot>/content/workflows" `
            -Condition ($r.path -like "$projectTier*")

        # 3) Same name in both — project wins
        $r = Find-Workflow -BotRoot $botRoot -Name "shared-name"
        Assert-True -Name "shared-name resolves" -Condition ($r.ok)
        Assert-Equal -Name "shared-name source (project wins)" -Expected "project" -Actual $r.source
        $m = Read-WorkflowManifest -WorkflowDir $r.path
        Assert-Equal -Name "shared-name parsed from project copy" `
            -Expected "shared-PR" -Actual $m.description

        # 4) Missing name → WorkflowNotFound
        $r = Find-Workflow -BotRoot $botRoot -Name "does-not-exist"
        Assert-True -Name "missing returns ok=false" -Condition (-not $r.ok)
        Assert-Equal -Name "missing reason is WorkflowNotFound" -Expected "WorkflowNotFound" -Actual $r.reason
        Assert-True -Name "missing tried both tier paths" -Condition ($r.tried.Count -eq 2)

        # ---- Discover-Workflows ----

        $all = @(Discover-Workflows -BotRoot $botRoot)
        Assert-Equal -Name "Discover returns one entry per name" -Expected 3 -Actual $all.Count

        $names = @($all | ForEach-Object { $_.name })
        Assert-True -Name "Discover includes framework-only" -Condition ($names -contains 'framework-only')
        Assert-True -Name "Discover includes project-only" -Condition ($names -contains 'project-only')
        Assert-True -Name "Discover includes shared-name" -Condition ($names -contains 'shared-name')

        $shared = $all | Where-Object { $_.name -eq 'shared-name' } | Select-Object -First 1
        Assert-Equal -Name "Discover marks override on same-name" `
            -Expected "project (overrides framework)" -Actual $shared.source

        $frameworkEntry = $all | Where-Object { $_.name -eq 'framework-only' } | Select-Object -First 1
        Assert-Equal -Name "Discover framework-only source" `
            -Expected "framework" -Actual $frameworkEntry.source

        $projectEntry = $all | Where-Object { $_.name -eq 'project-only' } | Select-Object -First 1
        Assert-Equal -Name "Discover project-only source" `
            -Expected "project" -Actual $projectEntry.source

        # Discover should sort by name (deterministic across platforms)
        $sorted = @($names) -join ","
        $expected = @(($names | Sort-Object)) -join ","
        Assert-Equal -Name "Discover output is sorted by name" -Expected $expected -Actual $sorted

        # ---- Get-WorkflowTierRoots ----

        $roots = Get-WorkflowTierRoots -BotRoot $botRoot
        Assert-True -Name "tier roots include 'project'" -Condition ($roots.Contains('project'))
        Assert-True -Name "tier roots include 'framework'" -Condition ($roots.Contains('framework'))
        Assert-True -Name "project tier root = <botRoot>/content/workflows" `
            -Condition ($roots.project -eq (Join-Path $botRoot 'content' 'workflows'))
        Assert-True -Name "framework tier root = <DOTBOT_HOME>/content/workflows" `
            -Condition ($roots.framework -eq (Join-Path $prd13FrameworkRoot 'content' 'workflows'))

        # ---- Edge case: invalid workflow.json (empty file) is ignored ----

        $badDir = Join-Path $projectTier "broken"
        New-Item -ItemType Directory -Path $badDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $badDir "workflow.json") -Force | Out-Null  # zero-byte
        $r = Find-Workflow -BotRoot $botRoot -Name "broken"
        Assert-True -Name "empty workflow.json ⇒ not found" -Condition (-not $r.ok)

        $all = @(Discover-Workflows -BotRoot $botRoot)
        Assert-Equal -Name "Discover ignores empty workflow.json" -Expected 3 -Actual $all.Count

    } finally {
        if ($null -ne $savedDotbotHomePRD13 -and $savedDotbotHomePRD13 -ne '') {
            $env:DOTBOT_HOME = $savedDotbotHomePRD13
        } elseif (Test-Path Env:DOTBOT_HOME) {
            Remove-Item Env:DOTBOT_HOME
        }
        if (Test-Path $prd13ProjectRoot)   { Remove-Item -Path $prd13ProjectRoot   -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $prd13FrameworkRoot) { Remove-Item -Path $prd13FrameworkRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WorkflowRun.workflow_path + workflow_source schema fields
# ═══════════════════════════════════════════════════════════════════

Write-Host " WorkflowRun.workflow_path / workflow_source" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (-not (Get-Command New-WorkflowRunRecord -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking
}

# Sanity: builder accepts the new params
$run = New-WorkflowRunRecord `
    -WorkflowName 'start-from-repo' `
    -StartedBy 'cli' `
    -TaskIds @() `
    -WorkflowPath '/tmp/.bot/workflows/start-from-repo' `
    -WorkflowSource 'project (overrides framework)'

Assert-Equal -Name "run.workflow_path round-trips" `
    -Expected '/tmp/.bot/workflows/start-from-repo' -Actual $run.workflow_path
Assert-Equal -Name "run.workflow_source round-trips" `
    -Expected 'project (overrides framework)' -Actual $run.workflow_source

# workflow_source must be from the known set
$rejectErrs = Test-WorkflowRunRecord -Record @{
    schema_version  = 1
    run_id          = 'wr_AbCd1234'
    workflow_name   = 'wf'
    started_at      = '2026-01-01T00:00:00Z'
    task_ids        = @()
    started_by      = 'cli'
    workflow_source = 'bogus-tier'
}
Assert-True -Name "bogus workflow_source is rejected" `
    -Condition (($rejectErrs -join "`n") -match 'workflow_source')

# Record without workflow_path is still valid
$legacyErrs = Test-WorkflowRunRecord -Record @{
    schema_version = 1
    run_id         = 'wr_AbCd1234'
    workflow_name  = 'wf'
    started_at    = '2026-01-01T00:00:00Z'
    task_ids      = @()
    started_by    = 'cli'
}
Assert-True -Name "legacy run record (no workflow_path) still valid" `
    -Condition ($legacyErrs.Count -eq 0)

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# dotbot workflow scaffold CLI
# ═══════════════════════════════════════════════════════════════════

Write-Host " dotbot workflow scaffold" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if ($true) {
    # The scaffold script uses Dotbot.Core's path helpers to locate the project.
    # We exercise the logical contract inline rather than invoking the script:
    # framework workflow exists → copy lands in project tier; refuses without
    # -Force on conflict; respects -Force. Copy-Item + the same checks the
    # script makes.
    $scaffRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-prd13scaff-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    $sBot = Join-Path $scaffRoot ".bot"
    try {
        $roots = @{
            framework = (Join-Path $sBot "content/workflows")
            project   = (Join-Path $sBot "workflows")
        }
        # Seed framework copy
        $src = Join-Path $roots.framework "start-from-repo"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        @'
{
  "name": "start-from-repo",
  "version": "1.0",
  "description": "framework copy"
}
'@ | Set-Content (Join-Path $src "workflow.json") -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $src "recipes/prompts") -Force | Out-Null
        Set-Content (Join-Path $src "recipes/prompts/01-step.md") -Value "# step" -Encoding UTF8

        # ---- 1) Copy fresh into empty project tier ----
        $target = Join-Path $roots.project "start-from-repo"
        if (-not (Test-Path $roots.project)) { New-Item -ItemType Directory -Path $roots.project -Force | Out-Null }
        Copy-Item -Path $src -Destination $target -Recurse -Force

        Assert-True -Name "scaffold creates target dir" -Condition (Test-Path $target)
        Assert-True -Name "scaffold copies workflow.json" -Condition (Test-Path (Join-Path $target "workflow.json"))
        Assert-True -Name "scaffold copies recipes/" -Condition (Test-Path (Join-Path $target "recipes/prompts/01-step.md"))

        # Project copy now resolves first
        $r = Find-Workflow -BotRoot $sBot -Name "start-from-repo"
        Assert-Equal -Name "post-scaffold resolves from project tier" -Expected "project" -Actual $r.source

        # ---- 2) Refuse to clobber without -Force ----
        # Logic-side check: script tests (Test-Path $targetDir) -and -not $Force
        $existsAfter = Test-Path $target
        Assert-True -Name "subsequent scaffold sees existing target" -Condition $existsAfter

        # ---- 3) Discover surfaces override ----
        $all = @(Discover-Workflows -BotRoot $sBot)
        $entry = $all | Where-Object { $_.name -eq 'start-from-repo' } | Select-Object -First 1
        Assert-Equal -Name "scaffold result is an override entry" `
            -Expected "project (overrides framework)" -Actual $entry.source
    } finally {
        if (Test-Path $scaffRoot) { Remove-Item -Path $scaffRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Workflow Manifest"

if (-not $allPassed) {
    exit 1
}
