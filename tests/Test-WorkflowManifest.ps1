#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit tests for workflow manifest functions.
.DESCRIPTION
    Tests the workflow-manifest.ps1 functions directly from repo source.
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
. (Join-Path $repoRoot "core/runtime/modules/workflow-manifest.ps1")

# Check prerequisite: powershell-yaml needed for Read-WorkflowManifest
$yamlModule = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
$hasYaml = $null -ne $yamlModule

# ═══════════════════════════════════════════════════════════════════
# TEST-MANIFESTCONDITION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  TEST-MANIFESTCONDITION" -ForegroundColor Cyan
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

    # Real workflow.yaml pattern: new_project mode
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        "!.bot/workspace/product/mission.md",
        "!.git/refs/heads/*"
    )
    Assert-True -Name "New project mode (no docs, no commits) → false when both exist" -Condition (-not $result)

    # Real workflow.yaml pattern: existing_code mode
    $result = Test-ManifestCondition -ProjectRoot $conditionRoot -Condition @(
        "!.bot/workspace/product/mission.md",
        ".git/refs/heads/*"
    )
    Assert-True -Name "Existing code mode (no docs, has commits) → false when docs exist" -Condition (-not $result)

    # Real workflow.yaml pattern: has_docs mode
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
# READ-WORKFLOWMANIFEST
# ═══════════════════════════════════════════════════════════════════

Write-Host "  READ-WORKFLOWMANIFEST" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (-not $hasYaml) {
    Write-TestResult -Name "Read-WorkflowManifest tests" -Status Skip -Message "powershell-yaml not installed"
} else {
    # start-from-prompt workflow (canonical default after PR-5)
    $promptManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\start-from-prompt")
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

    # start-from-jira workflow
    $jiraManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\start-from-jira")
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
    $prManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\start-from-pr")
    Assert-Equal -Name "PR manifest name" -Expected "start-from-pr" -Actual $prManifest.name
    Assert-True -Name "PR manifest has tasks" `
        -Condition ($prManifest.tasks -and $prManifest.tasks.Count -ge 3) `
        -Message "Expected at least 3 tasks, got: $($prManifest.tasks.Count)"
    Assert-True -Name "PR manifest has requires.cli_tools" `
        -Condition ($prManifest.requires -and $prManifest.requires.cli_tools -and @($prManifest.requires.cli_tools).Count -gt 0) `
        -Message "Expected cli_tools in requires"

    # start-from-repo workflow
    $repoManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\start-from-repo")
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
    $emptyManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\nonexistent-workflow")
    Assert-True -Name "Non-existent dir returns default manifest with name" `
        -Condition ($emptyManifest.name -eq "nonexistent-workflow") `
        -Message "Expected name from dir leaf"
    Assert-True -Name "Non-existent dir returns empty tasks" `
        -Condition ($emptyManifest.tasks.Count -eq 0) `
        -Message "Expected empty tasks"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CONVERT-MANIFESTREQUIRESTOPREFLIGHTCHECKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CONVERT-MANIFESTREQUIRESTOPREFLIGHTCHECKS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Hashtable input (as parsed by powershell-yaml)
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

$taskRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-wftask-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
$taskBotDir = Join-Path $taskRoot ".bot"
New-Item -ItemType Directory -Path (Join-Path $taskBotDir "workspace\tasks\todo") -Force | Out-Null

try {
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

    $result = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "start-from-jira" -TaskDef $taskDef
    Assert-True -Name "New-WorkflowTask returns id" `
        -Condition (-not [string]::IsNullOrEmpty($result.id)) -Message "No id returned"
    Assert-Equal -Name "New-WorkflowTask returns name" -Expected "Fetch Jira Context" -Actual $result.name
    Assert-True -Name "New-WorkflowTask returns file" `
        -Condition (-not [string]::IsNullOrEmpty($result.file)) -Message "No file returned"

    # Verify the task JSON file
    $taskFile = Join-Path $taskBotDir "workspace\tasks\todo" $result.file
    Assert-PathExists -Name "Task JSON file created" -Path $taskFile
    if (Test-Path $taskFile) {
        $taskJson = Get-Content $taskFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "Task JSON has correct name" -Expected "Fetch Jira Context" -Actual $taskJson.name
        Assert-Equal -Name "Task JSON has correct type" -Expected "prompt" -Actual $taskJson.type
        Assert-Equal -Name "Task JSON has correct workflow" -Expected "start-from-jira" -Actual $taskJson.workflow
        Assert-Equal -Name "Task JSON has correct priority" -Expected 1 -Actual $taskJson.priority
        Assert-Equal -Name "Task JSON has correct status" -Expected "todo" -Actual $taskJson.status
        Assert-Equal -Name "Task JSON has on_failure" -Expected "halt" -Actual $taskJson.on_failure
        Assert-True -Name "Task JSON has outputs" `
            -Condition (@($taskJson.outputs).Count -eq 1) -Message "Expected 1 output"
        Assert-True -Name "Task JSON has condition" `
            -Condition ($taskJson.condition -eq ".bot/workspace/product/research-repos.md") -Message "Condition not set"
    }

    # Barrier task — verify boolean defaults
    $barrierDef = @{
        name = "Execute Research"
        type = "barrier"
        depends_on = @("Plan Internet Research", "Plan Atlassian Research")
        optional = $true
        priority = 6
    }

    $barrierResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "start-from-jira" -TaskDef $barrierDef
    $barrierFile = Join-Path $taskBotDir "workspace\tasks\todo" $barrierResult.file
    if (Test-Path $barrierFile) {
        $barrierJson = Get-Content $barrierFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "Barrier task type" -Expected "barrier" -Actual $barrierJson.type
        Assert-True -Name "Barrier task skip_analysis defaults to true" `
            -Condition ($barrierJson.skip_analysis -eq $true) -Message "Expected skip_analysis=true for non-prompt"
        Assert-True -Name "Barrier task skip_worktree defaults to true" `
            -Condition ($barrierJson.skip_worktree -eq $true) -Message "Expected skip_worktree=true for non-prompt"
        Assert-Equal -Name "Barrier task has 2 dependencies" `
            -Expected 2 -Actual @($barrierJson.dependencies).Count
    }

    # Script task
    $scriptDef = @{
        name = "Task Group Expansion"
        type = "script"
        script = "expand-task-groups.ps1"
        priority = 4
    }

    $scriptResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "default" -TaskDef $scriptDef
    $scriptFile = Join-Path $taskBotDir "workspace\tasks\todo" $scriptResult.file
    if (Test-Path $scriptFile) {
        $scriptJson = Get-Content $scriptFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "Script task type" -Expected "script" -Actual $scriptJson.type
        Assert-Equal -Name "Script task workflow" -Expected "default" -Actual $scriptJson.workflow
    }

    # task_gen + workflow: "*.md" → should become prompt_template with prompt field
    $taskGenPromptDef = @{
        name     = "Plan Internet Research"
        type     = "task_gen"
        workflow = "02a-plan-internet-research.md"
        priority = 1
    }
    $tgpResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "default" -TaskDef $taskGenPromptDef
    $tgpFile = Join-Path $taskBotDir "workspace\tasks\todo" $tgpResult.file
    if (Test-Path $tgpFile) {
        $tgpJson = Get-Content $tgpFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "task_gen+workflow .md maps to prompt_template type" `
            -Expected "prompt_template" -Actual $tgpJson.type
        Assert-Equal -Name "task_gen+workflow .md sets correct prompt path" `
            -Expected "recipes/prompts/02a-plan-internet-research.md" -Actual $tgpJson.prompt
        Assert-Equal -Name "task_gen+workflow .md workflow is folder name not filename" `
            -Expected "default" -Actual $tgpJson.workflow
    }

    # task_gen + workflow: non-.md value → should stay task_gen (workflow name for filtering)
    $taskGenFilterDef = @{
        name     = "Generate Scoring Tasks"
        type     = "task_gen"
        workflow = "scoring"
        script   = "generate-scoring-tasks.ps1"
        priority = 2
    }
    $tgfResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "scoring" -TaskDef $taskGenFilterDef
    $tgfFile = Join-Path $taskBotDir "workspace\tasks\todo" $tgfResult.file
    if (Test-Path $tgfFile) {
        $tgfJson = Get-Content $tgfFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "task_gen+non-.md workflow stays task_gen type" `
            -Expected "task_gen" -Actual $tgfJson.type
        Assert-True -Name "task_gen+non-.md workflow has no prompt field" `
            -Condition (-not $tgfJson.PSObject.Properties['prompt'] -or -not $tgfJson.prompt) `
            -Message "Expected no prompt field on plain task_gen"
    }

    # Task with post_script — regression for andresharpe/dotbot#222
    $postScriptDef = @{
        name = "Task With Post Hook"
        type = "script"
        script = "do-work.ps1"
        post_script = "post-phase-task-groups.ps1"
        priority = 5
    }

    $postResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "default" -TaskDef $postScriptDef
    $postFile = Join-Path $taskBotDir "workspace\tasks\todo" $postResult.file
    if (Test-Path $postFile) {
        $postJson = Get-Content $postFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "post_script field preserved in task JSON" `
            -Expected "post-phase-task-groups.ps1" -Actual $postJson.post_script
    }

    # Task without post_script — ensure field is absent (keeps task JSON clean)
    $noPostDef = @{
        name = "Task Without Post Hook"
        type = "script"
        script = "do-work.ps1"
        priority = 5
    }
    $noPostResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "default" -TaskDef $noPostDef
    $noPostFile = Join-Path $taskBotDir "workspace\tasks\todo" $noPostResult.file
    if (Test-Path $noPostFile) {
        $noPostJson = Get-Content $noPostFile -Raw | ConvertFrom-Json
        Assert-True -Name "post_script absent when not declared" `
            -Condition ($null -eq $noPostJson.PSObject.Properties['post_script'])
    }

    # Priority 0 — regression for priority=0 falsy bug (was silently replaced by default 50)
    $priorityZeroDef = @{
        name = "Highest Priority Task"
        type = "prompt"
        workflow = "00-launch.md"
        priority = 0
    }
    $pzResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "default" -TaskDef $priorityZeroDef
    $pzFile = Join-Path $taskBotDir "workspace\tasks\todo" $pzResult.file
    Assert-True -Name "Priority 0 task file created" `
        -Condition (Test-Path $pzFile)
    $pzJson = Get-Content $pzFile -Raw | ConvertFrom-Json
    Assert-Equal -Name "Priority 0 preserved (not replaced by default)" `
        -Expected 0 -Actual $pzJson.priority

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

} finally {
    Remove-Item -Path $envRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WORKFLOW YAML SCHEMA VALIDATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKFLOW YAML SCHEMA" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (-not $hasYaml) {
    Write-TestResult -Name "Workflow YAML schema tests" -Status Skip -Message "powershell-yaml not installed"
} else {
    $workflowProfiles = @("start-from-prompt", "start-from-jira", "start-from-pr", "start-from-repo")

    foreach ($wfProfile in $workflowProfiles) {
        $workflowPath = Join-Path $repoRoot "workflows\$wfProfile\workflow.yaml"
        Assert-PathExists -Name "workflow.yaml exists: $wfProfile" -Path $workflowPath

        if (Test-Path $workflowPath) {
            $manifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\$wfProfile")

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

# Provide no-op implementations of the theme/activity helpers that the
# post-script-runner calls. These normally come from DotBotTheme.psm1 and the
# runtime, but we only care about Invoke-PostScript's own behaviour here.
function Write-Status { param($Message, $Type) }
function Write-ProcessActivity { param($Id, $ActivityType, $Message) }

. (Join-Path $repoRoot "core/runtime/modules/post-script-runner.ps1")

$postRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-post-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $postRoot "core/runtime") -Force | Out-Null
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
    $okScript | Set-Content (Join-Path $postRoot "core/runtime/ok-post.ps1")

    $failScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
exit 7
'@
    $failScript | Set-Content (Join-Path $postRoot "core/runtime/fail-post.ps1")

    $scriptsDirScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
Set-Content (Join-Path $BotRoot "sentinel\scripts-ran.txt") "ok"
exit 0
'@
    $scriptsDirScript | Set-Content (Join-Path $postRoot "scripts\scripts-post.ps1")

    $settings = @{ foo = "bar" }
    $productDir = Join-Path $postRoot "workspace\product"

    # Happy path: default path resolution (core/runtime/<name>)
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "Sonnet" -ProcessId "proc-123" `
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
            -Condition ($sentinelContent -match "Model=Sonnet")
        Assert-True -Name "Invoke-PostScript: passes ProcessId" `
            -Condition ($sentinelContent -match "ProcessId=proc-123")
        Assert-True -Name "Invoke-PostScript: passes Settings hashtable" `
            -Condition ($sentinelContent -match "Setting=bar")
    }

    # Scripts/ prefix path resolution
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "Sonnet" -ProcessId "proc-123" `
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
            -Settings $settings -Model "Sonnet" -ProcessId "proc-123" `
            -RawPostScript "scripts\scripts-post.ps1"
    } catch { $threw = $true }
    Assert-True -Name "Invoke-PostScript: backslash separator is normalised" `
        -Condition (-not $threw)

    # Failing exit code is surfaced as a throw
    $threw = $false
    $errMsg = $null
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "Sonnet" -ProcessId "proc-123" `
            -RawPostScript "fail-post.ps1"
    } catch { $threw = $true; $errMsg = $_.Exception.Message }
    Assert-True -Name "Invoke-PostScript: non-zero exit code throws" -Condition $threw
    Assert-True -Name "Invoke-PostScript: exit code 7 surfaced in error" `
        -Condition ($errMsg -match "7")

    # Missing script file is surfaced as a throw before any invocation
    $threw = $false
    try {
        Invoke-PostScript -BotRoot $postRoot -ProductDir $productDir `
            -Settings $settings -Model "Sonnet" -ProcessId "proc-123" `
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
New-Item -ItemType Directory -Path (Join-Path $wrapRoot "core/runtime") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $wrapRoot "sentinel") -Force | Out-Null

try {
    # Reusable scripts from the previous section aren't available — create fresh
    $okScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
Set-Content (Join-Path $BotRoot "sentinel\wrap-ok.txt") "ran"
exit 0
'@
    $okScript | Set-Content (Join-Path $wrapRoot "core/runtime/wrap-ok.ps1")

    $failScript = @'
param([string]$BotRoot, [string]$ProductDir, $Settings, [string]$Model, [string]$ProcessId)
exit 3
'@
    $failScript | Set-Content (Join-Path $wrapRoot "core/runtime/wrap-fail.ps1")

    $settings = @{}
    $productDir = Join-Path $wrapRoot "workspace\product"

    # No post_script declared → returns $null, no-op
    $taskNoHook = [pscustomobject]@{ name = "No hook"; post_script = $null }
    $result = Invoke-TaskPostScriptIfPresent -Task $taskNoHook -BotRoot $wrapRoot `
        -ProductDir $productDir -Settings $settings -Model "Sonnet" -ProcessId "p1"
    Assert-True -Name "Wrapper: no post_script returns null" -Condition ($null -eq $result)

    # Happy path → returns $null, sentinel exists
    $taskOk = [pscustomobject]@{ name = "Ok hook"; post_script = "wrap-ok.ps1" }
    $result = Invoke-TaskPostScriptIfPresent -Task $taskOk -BotRoot $wrapRoot `
        -ProductDir $productDir -Settings $settings -Model "Sonnet" -ProcessId "p1"
    Assert-True -Name "Wrapper: success returns null" -Condition ($null -eq $result)
    Assert-PathExists -Name "Wrapper: success ran the script" `
        -Path (Join-Path $wrapRoot "sentinel\wrap-ok.txt")

    # Failure → returns error string, does not throw
    $taskFail = [pscustomobject]@{ name = "Fail hook"; post_script = "wrap-fail.ps1" }
    $threw = $false
    $result = $null
    try {
        $result = Invoke-TaskPostScriptIfPresent -Task $taskFail -BotRoot $wrapRoot `
            -ProductDir $productDir -Settings $settings -Model "Sonnet" -ProcessId "p1"
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

$workflowProcessPath = Join-Path $repoRoot "core/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1"

Assert-PathExists -Name "Invoke-WorkflowProcess.ps1 exists" -Path $workflowProcessPath

$workflowSrc = Get-Content $workflowProcessPath -Raw

Assert-True -Name "Invoke-WorkflowProcess dot-sources post-script-runner" `
    -Condition ($workflowSrc -match 'post-script-runner\.ps1')

$wrapperCallCount = ([regex]::Matches($workflowSrc, 'Invoke-TaskPostScriptIfPresent')).Count
Assert-True -Name "Invoke-WorkflowProcess calls wrapper in both branches (>=2 call sites)" `
    -Condition ($wrapperCallCount -ge 2)

# Ensure the Claude-branch post_script failure escalates to needs-input/ rather
# than falling into generic failure cleanup (worktree destruction, failure-counter
# bump). Regression guard for the Path B bug traced during review.
Assert-True -Name "Invoke-WorkflowProcess tracks postScriptFailed flag" `
    -Condition ($workflowSrc -match '\$postScriptFailed\s*=\s*\$true')
Assert-True -Name "Invoke-WorkflowProcess has elseif (postScriptFailed) branch" `
    -Condition ($workflowSrc -match 'elseif\s*\(\s*\$postScriptFailed\s*\)')
Assert-True -Name "Invoke-WorkflowProcess calls Invoke-PostScriptFailureEscalation" `
    -Condition ($workflowSrc -match 'Invoke-PostScriptFailureEscalation')

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TASK-RUNNER PARITY (PR-3a)
# ═══════════════════════════════════════════════════════════════════
# Regression guards for the four parity items the task-runner absorbed
# from the legacy execution engine: briefing-file injection, interview-summary
# injection, outputs validation, front_matter_docs. If any of these
# helpers gets removed, every shipped workflow.yaml silently regresses.

Write-Host "  TASK-RUNNER PARITY (briefing, interview-summary, outputs, front-matter)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Invoke-WorkflowProcess defines Get-WorkflowPromptContext helper" `
    -Condition ($workflowSrc -match 'function\s+Get-WorkflowPromptContext')
Assert-True -Name "Invoke-WorkflowProcess injects context into analysis prompt" `
    -Condition ($workflowSrc -match '\$promptContext\s*=\s*Get-WorkflowPromptContext')
Assert-True -Name "Invoke-WorkflowProcess injects context into execution prompt" `
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

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# TASK-RUNNER INTERVIEW TASK TYPE (PR-3b, #220)
# ═══════════════════════════════════════════════════════════════════
# The task-runner now handles type:interview tasks by wrapping
# Invoke-InterviewLoop. Regression guard against the dispatch case
# being removed once the legacy engine is deleted.

Write-Host "  TASK-RUNNER INTERVIEW TASK TYPE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-True -Name "Invoke-WorkflowProcess dot-sources InterviewLoop.ps1" `
    -Condition ($workflowSrc -match 'InterviewLoop\.ps1')
Assert-True -Name "Invoke-WorkflowProcess has 'interview' case in task-type switch" `
    -Condition ($workflowSrc -match "'interview'\s*\{")
Assert-True -Name "Invoke-WorkflowProcess interview case calls Invoke-InterviewLoop" `
    -Condition ($workflowSrc -match 'Invoke-InterviewLoop')
Assert-True -Name "Interview case resolves user prompt from workflow-launch-prompt.txt" `
    -Condition ($workflowSrc -match 'workflow-launch-prompt\.txt')

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

# ── Fix #1: workflow-manifest.ps1 must import ManifestCondition.psm1 with
# -Global so Test-ManifestCondition remains visible when workflow-manifest.ps1
# is dot-sourced from inside a function/scriptblock scope (the pattern
# server.ps1 and task-get-next/script.ps1 use). Without -Global the imported
# function ends up in a module scope that HTTP route handlers cannot reach.
$workflowManifestPath = Join-Path $repoRoot "core/runtime/modules/workflow-manifest.ps1"
$workflowManifestSrc = Get-Content $workflowManifestPath -Raw

Assert-True -Name "Fix#1: workflow-manifest.ps1 Import-Module for ManifestCondition uses -Global" `
    -Condition ($workflowManifestSrc -match 'Import-Module\s+\(Join-Path\s+\$PSScriptRoot\s+"ManifestCondition\.psm1"\)[^\r\n]*-Global')

# Regression: dot-source workflow-manifest.ps1 inside a nested scriptblock and
# verify Test-ManifestCondition remains visible *after that child scope exits*
# via the -Global import. This reproduces the HTTP route handler failure mode:
# if the module is imported without -Global, the function would be visible
# only inside the scriptblock and disappear when it returns. Checking
# Get-Command outside the scriptblock is what actually validates -Global.
Remove-Module ManifestCondition -Force -ErrorAction SilentlyContinue
$nestedProbe = $false
try {
    & {
        . $workflowManifestPath
    }
    $nestedProbe = (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue) -ne $null
} finally {
    Remove-Module ManifestCondition -Force -ErrorAction SilentlyContinue
}
Assert-True -Name "Fix#1: Test-ManifestCondition visible after nested dot-source of workflow-manifest.ps1" `
    -Condition $nestedProbe

# Fix #2 (legacy engine auto-push) was removed in PR-3 along with the
# legacy engine. Task-runner's squash-merge in Complete-TaskWorktree handles
# pushing for completed tasks; phase-level auto-push no longer applies.

# ── Fix #3: workflow prompt templates must instruct agents to retry the same
# select: query rather than broadening when the MCP server is still warming up.
$promptFiles = @(
    (Join-Path $repoRoot "workflows\start-from-prompt\recipes\prompts\03b-expand-task-group.md"),
    (Join-Path $repoRoot "workflows\start-from-prompt\recipes\prompts\01b-generate-decisions.md"),
    (Join-Path $repoRoot "core/prompts/98-analyse-task.md")
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
$decisionsPromptPath = Join-Path $repoRoot "workflows\start-from-prompt\recipes\prompts\01b-generate-decisions.md"
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
    (Join-Path $repoRoot "core/prompts/99-autonomous-task.md"),
    (Join-Path $repoRoot "workflows/start-from-jira/recipes/prompts/99-autonomous-task.md")
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
    Assert-True -Name "Fix#A: $parentDir/$relName has branch-conditional task/ guard" `
        -Condition ($src -match 'If\s+`\{\{BRANCH_NAME\}\}`\s+starts\s+with\s+`task/`')
    Assert-True -Name "Fix#A: $parentDir/$relName instructs push on shared branches" `
        -Condition ($src -match 'push\s+immediately\s+to\s+`origin/\{\{BRANCH_NAME\}\}`')
    Assert-True -Name "Fix#A: $parentDir/$relName cites 02-git-pushed.ps1 failure mode" `
        -Condition ($src -match '02-git-pushed\.ps1')
    Assert-True -Name "Fix#A: $parentDir/$relName no longer hardcodes 'git worktree on branch' assertion" `
        -Condition (-not ($src -match 'You are working in a \*\*git worktree\*\* on branch'))
}

# ── Batch 2, Fix B: 03a-plan-task-groups.md must include task-level rigor
# (schema, acceptance-criteria quality bar, effort sizing, dependency chain)
# that 03b-expand-task-group.md inherits during expansion.
$planTaskGroupsPath = Join-Path $repoRoot "workflows\start-from-prompt\recipes\prompts\03a-plan-task-groups.md"
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
$expandTaskGroupPath = Join-Path $repoRoot "workflows\start-from-prompt\recipes\prompts\03b-expand-task-group.md"
$expandTaskGroupSrc = Get-Content $expandTaskGroupPath -Raw
Assert-True -Name "Fix#B: 03b cross-links to 03a for schema/criteria/sizing" `
    -Condition ($expandTaskGroupSrc -match 'Inherits\s+from\s+03a-plan-task-groups\.md')
Assert-True -Name "Fix#B: 03b tells agent not to relax constraints during expansion" `
    -Condition ($expandTaskGroupSrc -match 'do\s+not\s+relax\s+them\s+during\s+expansion')

# ── Batch 2, Fix C: 98-analyse-task.md must guard mission/tech-stack/entity-model
# reads against the current task's outputs list, so tasks that produce those
# files (e.g. workflow Product Documents) do not error during pre-flight
# analysis trying to read files they are supposed to create.
$analyseTaskPath = Join-Path $repoRoot "core/prompts/98-analyse-task.md"
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

# ── Batch 2, Fix D: 98-analyse-task.md must treat .bot/recipes/standards/global
# as an optional directory; skip the glob if it does not exist.
Assert-True -Name "Fix#D: 98-analyse-task.md marks standards/global listing as skip-if-missing" `
    -Condition ($analyseTaskSrc -match '(?s)List\s+available\s+standards\s+\(skip\s+if\s+directory\s+missing\)')
Assert-True -Name "Fix#D: 98-analyse-task.md describes standards/global as optional" `
    -Condition ($analyseTaskSrc -match '`\.bot/recipes/standards/global/`\s+directory\s+is\s+optional')
Assert-True -Name "Fix#D: 98-analyse-task.md tells agent not to treat missing standards/global as error" `
    -Condition ($analyseTaskSrc -match 'Do\s+\*\*not\*\*\s+treat\s+the\s+missing\s+directory\s+as\s+an\s+error')

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

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Workflow Manifest"

if (-not $allPassed) {
    exit 1
}

