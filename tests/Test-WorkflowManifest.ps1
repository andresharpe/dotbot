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
. (Join-Path $repoRoot "workflows\default\systems\runtime\modules\workflow-manifest.ps1")

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
    # Default workflow
    $defaultManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\default")
    Assert-Equal -Name "Default manifest name" -Expected "default" -Actual $defaultManifest.name
    Assert-Equal -Name "Default manifest version" -Expected "3.5.0" -Actual $defaultManifest.version
    Assert-True -Name "Default manifest has tasks" `
        -Condition ($defaultManifest.tasks -and $defaultManifest.tasks.Count -gt 0) `
        -Message "Expected tasks array, got: $($defaultManifest.tasks.Count)"
    Assert-True -Name "Default manifest has form.modes" `
        -Condition ($null -ne $defaultManifest.form -and $null -ne $defaultManifest.form.modes -and $defaultManifest.form.modes.Count -gt 0) `
        -Message "Expected form.modes array"

    # Verify form.modes have required shape
    $newProjectMode = $defaultManifest.form.modes | Where-Object { $_.id -eq 'new_project' }
    Assert-True -Name "Default form.modes has new_project" `
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

    $hasDocsMode = $defaultManifest.form.modes | Where-Object { $_.id -eq 'has_docs' }
    Assert-True -Name "Default form.modes has has_docs (hidden)" `
        -Condition ($null -ne $hasDocsMode -and $hasDocsMode.hidden -eq $true) -Message "has_docs mode should be hidden"

    # Default manifest task dependency graph validation
    $taskNames = @($defaultManifest.tasks | ForEach-Object { $_.name })
    $uniqueNames = @($taskNames | Sort-Object -Unique)
    Assert-Equal -Name "Default manifest task names are unique" `
        -Expected $taskNames.Count -Actual $uniqueNames.Count

    foreach ($task in $defaultManifest.tasks) {
        if ($task.depends_on) {
            foreach ($dep in @($task.depends_on)) {
                Assert-True -Name "Default task '$($task.name)' dep '$dep' exists" `
                    -Condition ($dep -in $taskNames) `
                    -Message "Dependency '$dep' not found in task names"
            }
        }
    }

    # Kickstart-via-jira workflow
    $jiraManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\kickstart-via-jira")
    Assert-Equal -Name "Jira manifest name" -Expected "kickstart-via-jira" -Actual $jiraManifest.name
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

    # Kickstart-via-pr workflow
    $prManifest = Read-WorkflowManifest -WorkflowDir (Join-Path $repoRoot "workflows\kickstart-via-pr")
    Assert-Equal -Name "PR manifest name" -Expected "kickstart-via-pr" -Actual $prManifest.name
    Assert-True -Name "PR manifest has tasks" `
        -Condition ($prManifest.tasks -and $prManifest.tasks.Count -ge 3) `
        -Message "Expected at least 3 tasks, got: $($prManifest.tasks.Count)"
    Assert-True -Name "PR manifest has requires.cli_tools" `
        -Condition ($prManifest.requires -and $prManifest.requires.cli_tools -and @($prManifest.requires.cli_tools).Count -gt 0) `
        -Message "Expected cli_tools in requires"

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
        workflow = "00-kickstart-interview.md"
        priority = 1
        outputs = @("briefing/jira-context.md")
        condition = ".bot/workspace/product/research-repos.md"
        on_failure = "halt"
    }

    $result = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "kickstart-via-jira" -TaskDef $taskDef
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
        Assert-Equal -Name "Task JSON has correct workflow" -Expected "kickstart-via-jira" -Actual $taskJson.workflow
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

    $barrierResult = New-WorkflowTask -ProjectBotDir $taskBotDir -WorkflowName "kickstart-via-jira" -TaskDef $barrierDef
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
    $workflowProfiles = @("default", "kickstart-via-jira", "kickstart-via-pr")

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
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Workflow Manifest"

if (-not $allPassed) {
    exit 1
}
