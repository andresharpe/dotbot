#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Source-based task action tests for roadmap ignore/edit/delete behavior.
.DESCRIPTION
    Validates the desired behavior for audited todo edits/deletes, version
    restore, and dependency-aware ignore propagation directly from repo source.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host "  Source Task Action Tests" -ForegroundColor Blue
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

function New-SourceBackedTestProject {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $projectRoot = New-TestProject -Prefix "dotbot-task-actions"
    $botDir = Join-Path $projectRoot ".bot"
    New-Item -ItemType Directory -Path $botDir -Force | Out-Null

    # Mirror what dotbot init produces post-PR-5: core/ scaffolding (settings,
    # hooks, root scripts) plus core/ itself, with start-from-prompt as the
    # canonical workflow.
    $coreSrc = Join-Path $RepoRoot "core"
    if (Test-Path $coreSrc) {
        Copy-Item -Path $coreSrc -Destination (Join-Path $botDir "core") -Recurse -Force
        foreach ($f in @("go.ps1", "init.ps1", "README.md", ".gitignore")) {
            $src = Join-Path $coreSrc $f
            if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $botDir $f) -Force }
        }
        foreach ($subdir in @("settings", "hooks")) {
            $src = Join-Path $coreSrc $subdir
            if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $botDir $subdir) -Recurse -Force }
        }
    }
    $wfSrc = Join-Path $RepoRoot "workflows/start-from-prompt"
    if (Test-Path $wfSrc) {
        $wfDest = Join-Path $botDir "workflows/start-from-prompt"
        New-Item -ItemType Directory -Path $wfDest -Force | Out-Null
        Copy-Item -Path (Join-Path $wfSrc "*") -Destination $wfDest -Recurse -Force
    }

    $workspaceDirs = @(
        "workspace\tasks\todo",
        "workspace\tasks\todo\edited_tasks",
        "workspace\tasks\todo\deleted_tasks",
        "workspace\tasks\analysing",
        "workspace\tasks\analysed",
        "workspace\tasks\needs-input",
        "workspace\tasks\in-progress",
        "workspace\tasks\done",
        "workspace\tasks\split",
        "workspace\tasks\skipped",
        "workspace\tasks\cancelled",
        "workspace\product",
        "workspace\sessions\runs",
        ".control",
        ".control\processes"
    )

    foreach ($dir in $workspaceDirs) {
        $fullPath = Join-Path $botDir $dir
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        }
    }

    $settingsPath = Join-Path $botDir "settings\settings.default.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if (-not $settings.PSObject.Properties['instance_id'] -or -not $settings.instance_id) {
            $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue ([guid]::NewGuid().ToString()) -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
        }
    }

    return $projectRoot
}

function New-TestTaskFile {
    param(
        [Parameter(Mandatory)]
        [string]$TasksTodoDir,
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Description,
        [Parameter(Mandatory)]
        [int]$Priority,
        [string[]]$Dependencies = @()
    )

    $task = [ordered]@{
        id = $TaskId
        name = $Name
        description = $Description
        category = "feature"
        priority = $Priority
        effort = "S"
        status = "todo"
        dependencies = @($Dependencies)
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    }

    $filePath = Join-Path $TasksTodoDir "$TaskId.json"
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    return $filePath
}

function Get-ExpectedAuditUsername {
    if ($IsWindows) {
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            if ($identity -and $identity.Name) {
                return $identity.Name
            }
        } catch {
            # Fall back to cross-platform APIs below.
        }
    }

    $user = [System.Environment]::UserName

    if ($IsWindows) {
        $domain = [System.Environment]::UserDomainName
        if ($domain -and $user -and $domain -ne $user) {
            return "$domain\$user"
        }
    }

    if ($user) {
        return $user
    }

    return "unknown"
}

$testProject = $null

try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    $botDir = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir = Join-Path $tasksBaseDir "todo"

    $global:DotbotProjectRoot = $testProject

    $taskMutationModule = Join-Path $botDir "core/mcp/modules/TaskMutation.psm1"
    Assert-PathExists -Name "TaskMutation module exists" -Path $taskMutationModule

    if (-not (Test-Path $taskMutationModule)) {
        $allPassed = Write-TestSummary -LayerName "Task Action Source Tests"
        if (-not $allPassed) {
            exit 1
        }
        exit 0
    }

    Import-Module $taskMutationModule -Force

    Assert-True -Name "TaskMutation exports Set-TaskIgnoreState" `
        -Condition ($null -ne (Get-Command Set-TaskIgnoreState -ErrorAction SilentlyContinue)) `
        -Message "Expected Set-TaskIgnoreState to be exported"
    Assert-True -Name "TaskMutation exports Update-TaskContent" `
        -Condition ($null -ne (Get-Command Update-TaskContent -ErrorAction SilentlyContinue)) `
        -Message "Expected Update-TaskContent to be exported"
    Assert-True -Name "TaskMutation exports Remove-TaskFromTodo" `
        -Condition ($null -ne (Get-Command Remove-TaskFromTodo -ErrorAction SilentlyContinue)) `
        -Message "Expected Remove-TaskFromTodo to be exported"
    Assert-True -Name "TaskMutation exports Get-TaskVersionHistory" `
        -Condition ($null -ne (Get-Command Get-TaskVersionHistory -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-TaskVersionHistory to be exported"
    Assert-True -Name "TaskMutation exports Restore-TaskVersion" `
        -Condition ($null -ne (Get-Command Restore-TaskVersion -ErrorAction SilentlyContinue)) `
        -Message "Expected Restore-TaskVersion to be exported"
    Assert-True -Name "TaskMutation exports Get-TaskIgnoreStateMap" `
        -Condition ($null -ne (Get-Command Get-TaskIgnoreStateMap -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-TaskIgnoreStateMap to be exported"
    Assert-True -Name "TaskMutation exports Get-RoadmapOverviewDependencyMap" `
        -Condition ($null -ne (Get-Command Get-RoadmapOverviewDependencyMap -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-RoadmapOverviewDependencyMap to be exported from TaskMutation"

    $taskStoreModule = Join-Path $botDir "core/mcp/modules/TaskStore.psm1"
    Assert-PathExists -Name "TaskStore module exists" -Path $taskStoreModule
    Import-Module $taskStoreModule -Force -DisableNameChecking
    Assert-True -Name "TaskStore exports Get-TasksBaseDir" `
        -Condition ($null -ne (Get-Command Get-TasksBaseDir -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-TasksBaseDir to be exported from TaskStore"
    Assert-True -Name "TaskStore exports Get-TodoDirectories" `
        -Condition ($null -ne (Get-Command Get-TodoDirectories -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-TodoDirectories to be exported from TaskStore"
    Assert-True -Name "TaskStore exports Initialize-TodoDirectories" `
        -Condition ($null -ne (Get-Command Initialize-TodoDirectories -ErrorAction SilentlyContinue)) `
        -Message "Expected Initialize-TodoDirectories to be exported from TaskStore"
    Assert-True -Name "TaskStore exports Get-TodoTaskRecord" `
        -Condition ($null -ne (Get-Command Get-TodoTaskRecord -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-TodoTaskRecord to be exported from TaskStore"
    Assert-True -Name "TaskStore exports Get-TaskSlug" `
        -Condition ($null -ne (Get-Command Get-TaskSlug -ErrorAction SilentlyContinue)) `
        -Message "Expected Get-TaskSlug to be exported from TaskStore"

    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-root" -Name "Root dependency" -Description "Dependency task" -Priority 10 | Out-Null
    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-dependent" -Name "Dependent task" -Description "Depends on root" -Priority 20 -Dependencies @("task-root") | Out-Null
    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-free" -Name "Independent task" -Description "Independent work" -Priority 30 | Out-Null
    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-deleted-only" -Name "Deleted-only task" -Description "Deleted without prior edits" -Priority 40 | Out-Null
    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-list-edit" -Name "List edit task" -Description "Task used to validate list editing" -Priority 50 | Out-Null

    $objectTaskPath = Join-Path $todoDir "task-object.json"
    [ordered]@{
        id = "task-object"
        name = "Structured task"
        description = "Structured task description"
        category = "analysis"
        priority = 35
        effort = "XS"
        status = "todo"
        dependencies = @()
        steps = @(
            [ordered]@{ text = "Check repo overview"; done = $false },
            [ordered]@{ text = "Validate usage notes"; done = $false }
        )
        acceptance_criteria = @(
            [ordered]@{ text = "README matches repo"; met = $false }
        )
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 20 | Set-Content -Path $objectTaskPath -Encoding UTF8

    $ignoreResult = Set-TaskIgnoreState -TaskId "task-root" -Ignored $true -Actor "dotbot-test"
    Assert-True -Name "Set-TaskIgnoreState returns success" `
        -Condition ($ignoreResult.success -eq $true) `
        -Message "Expected ignore result success=true"

    $ignoreMap = Get-TaskIgnoreStateMap -TasksBaseDir $tasksBaseDir
    Assert-True -Name "Ignored root task is marked manual + effective" `
        -Condition ($ignoreMap['task-root'].manual -eq $true -and $ignoreMap['task-root'].effective -eq $true) `
        -Message "Expected manual/effective ignore flags on root task"
    Assert-True -Name "Dependent task becomes auto-ignored when dependency is ignored" `
        -Condition ($ignoreMap['task-dependent'].effective -eq $true -and $ignoreMap['task-dependent'].manual -eq $false) `
        -Message "Expected dependent task to be auto-ignored"
    Assert-True -Name "Dependent task tracks blocking ignored dependency" `
        -Condition ($ignoreMap['task-dependent'].blocking_task_ids -contains 'task-root') `
        -Message "Expected ignored dependency source to be recorded"

    # Create a prompt_template task with a prompt field to verify index + task-get-next propagation
    $ptTaskPath = Join-Path $todoDir "task-prompt-template.json"
    [ordered]@{
        id           = "task-prompt-template"
        name         = "Plan Internet Research"
        description  = "Run Claude with a workflow prompt to generate tasks"
        category     = "workflow"
        priority     = 1
        effort       = "XS"
        status       = "todo"
        type         = "prompt_template"
        prompt       = "recipes/prompts/02a-plan-internet-research.md"
        workflow     = "default"
        script_path  = $null
        dependencies = @()
        acceptance_criteria = @()
        steps        = @()
        applicable_standards = @()
        applicable_agents    = @()
        skip_analysis  = $true
        skip_worktree  = $true
        created_at   = "2026-04-13T00:00:00Z"
        updated_at   = "2026-04-13T00:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $ptTaskPath -Encoding UTF8

    $taskIndexModule = Join-Path $botDir "core/mcp/modules/TaskIndexCache.psm1"
    Import-Module $taskIndexModule -Force
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

    # Verify TaskIndexCache stores the prompt field
    $ptIndexEntry = (Get-TaskIndex).Todo['task-prompt-template']
    Assert-True -Name "TaskIndexCache stores prompt field for prompt_template task" `
        -Condition ($ptIndexEntry -and $ptIndexEntry.prompt -eq "recipes/prompts/02a-plan-internet-research.md") `
        -Message "Expected index entry to carry prompt='recipes/prompts/02a-plan-internet-research.md'"

    # Verify task-get-next script returns prompt field.
    # Use an isolated temp index containing only the prompt_template task so priority
    # ordering does not interfere with the subsequent ignore-state assertions.
    $taskGetNextScript = Join-Path $botDir "core/mcp/tools/task-get-next/script.ps1"
    if (Test-Path $taskGetNextScript) {
        # Stub Write-BotLog — not available outside the full runtime context
        if (-not (Get-Command Write-BotLog -ErrorAction SilentlyContinue)) {
            function Write-BotLog { param([string]$Level, [string]$Message, $Exception) }
        }
        . $taskGetNextScript

        # Temp dir with only the prompt_template task
        $ptIsolatedBase = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-pt-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
        $ptIsolatedTodo = Join-Path $ptIsolatedBase "todo"
        New-Item -ItemType Directory -Path $ptIsolatedTodo -Force | Out-Null
        Copy-Item -Path $ptTaskPath -Destination (Join-Path $ptIsolatedTodo "task-prompt-template.json") -Force

        Initialize-TaskIndex -TasksBaseDir $ptIsolatedBase
        $getNextResult = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false; verbose = $false }
        Assert-True -Name "task-get-next returns prompt field on prompt_template task" `
            -Condition ($getNextResult.task -and $getNextResult.task.prompt -eq "recipes/prompts/02a-plan-internet-research.md") `
            -Message "Expected task-get-next to include prompt='recipes/prompts/02a-plan-internet-research.md'"
        $getNextVerbose = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false; verbose = $true }
        Assert-True -Name "task-get-next verbose returns prompt field on prompt_template task" `
            -Condition ($getNextVerbose.task -and $getNextVerbose.task.prompt -eq "recipes/prompts/02a-plan-internet-research.md") `
            -Message "Expected task-get-next verbose to include prompt field in returned task"

        Remove-Item -Path $ptIsolatedBase -Recurse -Force -ErrorAction SilentlyContinue
        # Restore main index (without the prompt_template task, which is priority 1 and would disrupt ordering tests)
        Remove-Item -Path $ptTaskPath -Force -ErrorAction SilentlyContinue
        Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    }

    $nextTask = Get-NextTask
    Assert-Equal -Name "Get-NextTask skips ignored tasks and blocked dependents" `
        -Expected "task-free" `
        -Actual $nextTask.id

    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-stale-source" -Name "Stale ignored source" -Description "Ignored task with stale todo copy" -Priority 15 | Out-Null
    New-TestTaskFile -TasksTodoDir $todoDir -TaskId "task-stale-dependent" -Name "Dependent on stale source" -Description "Should not stay blocked when source moved to done" -Priority 16 -Dependencies @("task-stale-source") | Out-Null
    $staleIgnoreResult = Set-TaskIgnoreState -TaskId "task-stale-source" -Ignored $true -Actor "dotbot-test"
    Assert-True -Name "Set-TaskIgnoreState can mark stale-source fixture ignored" `
        -Condition ($staleIgnoreResult.success -eq $true) `
        -Message "Expected stale-source ignore result success=true"
    Copy-Item -Path (Join-Path $todoDir "task-stale-source.json") -Destination (Join-Path $tasksBaseDir "done\task-stale-source.json") -Force
    $ignoreMapAfterStalePromotion = Get-TaskIgnoreStateMap -TasksBaseDir $tasksBaseDir
    Assert-True -Name "Stale todo copy does not keep dependents auto-ignored after source is done" `
        -Condition ($ignoreMapAfterStalePromotion['task-stale-dependent'].effective -eq $false) `
        -Message "Expected stale todo copy in done/todo overlap not to keep dependent blocked"
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    Update-TaskIndex
    $staleDependentIgnoreState = (Get-TaskIndex).IgnoreMap['task-stale-dependent']
    Assert-True -Name "Task index ignore map ignores stale todo copies once task is done" `
        -Condition (-not $staleDependentIgnoreState -or $staleDependentIgnoreState.effective -eq $false) `
        -Message "Expected task index ignore map not to auto-block dependent from stale todo copy"

    Assert-FileContains -Name "TaskMutation supports roadmap-overview dependency fallback" `
        -Path $taskMutationModule `
        -Pattern 'function Get-RoadmapOverviewDependencyMap'
    Assert-FileContains -Name "TaskMutation resolves fallback roadmap dependencies" `
        -Path $taskMutationModule `
        -Pattern 'function Get-ResolvedTaskDependencies'
    Assert-FileContains -Name "TaskIndexCache supports roadmap-overview dependency fallback" `
        -Path $taskIndexModule `
        -Pattern 'function Get-IgnoreRoadmapDependencyMap'
    Assert-FileContains -Name "TaskIndexCache resolves fallback roadmap dependencies" `
        -Path $taskIndexModule `
        -Pattern 'function Get-ResolvedIgnoreDependencies'
    Assert-FileContains -Name "TaskStore defines canonical Get-TodoTaskRecord" `
        -Path $taskStoreModule `
        -Pattern 'function Get-TodoTaskRecord'
    Assert-True -Name "TaskMutation does not define Get-TodoTaskRecord (delegated to TaskStore)" `
        -Condition (-not (Select-String -Path $taskMutationModule -Pattern 'function Get-TodoTaskRecord' -Quiet)) `
        -Message "Expected TaskMutation to delegate Get-TodoTaskRecord to TaskStore, not define it locally"
    Assert-True -Name "StateBuilder does not define Get-RoadmapOverviewDependencyMap (uses TaskMutation's)" `
        -Condition (-not (Select-String -Path (Join-Path $botDir "core/ui/modules/StateBuilder.psm1") -Pattern 'function Get-RoadmapOverviewDependencyMap' -Quiet)) `
        -Message "Expected StateBuilder to use TaskMutation's Get-RoadmapOverviewDependencyMap, not define it locally"
    Assert-FileContains -Name "TaskStore defines canonical Get-TaskSlug" `
        -Path $taskStoreModule `
        -Pattern 'function Get-TaskSlug'
    Assert-True -Name "TaskMutation does not define Get-TaskSlug (delegated to TaskStore)" `
        -Condition (-not (Select-String -Path $taskMutationModule -Pattern 'function Get-TaskSlug' -Quiet)) `
        -Message "Expected TaskMutation to use TaskStore's Get-TaskSlug, not define it locally"
    $worktreeManagerModule = Join-Path $botDir "core/runtime/modules/WorktreeManager.psm1"
    Assert-True -Name "WorktreeManager does not define Get-TaskSlug (delegated to TaskStore)" `
        -Condition (-not (Select-String -Path $worktreeManagerModule -Pattern 'function Get-TaskSlug' -Quiet)) `
        -Message "Expected WorktreeManager to use TaskStore's Get-TaskSlug, not define it locally"
    Assert-Equal -Name "Get-TaskSlug lowercases and collapses special chars" `
        -Expected "hello-world" `
        -Actual (Get-TaskSlug -TaskName "Hello World!")
    Assert-Equal -Name "Get-TaskSlug trims leading and trailing dashes" `
        -Expected "dotnet-upgrade" `
        -Actual (Get-TaskSlug -TaskName "--dotnet-upgrade--")
    Assert-Equal -Name "Get-TaskSlug caps at 50 chars and strips trailing dash" `
        -Expected ("a" * 50) `
        -Actual (Get-TaskSlug -TaskName ("a" * 55))


    $firstEdit = Update-TaskContent -TaskId "task-free" -Actor "dotbot-test" -Updates @{
        description = "Independent work updated"
        steps = @("Draft implementation")
    }
    Assert-True -Name "Update-TaskContent returns success" `
        -Condition ($firstEdit.success -eq $true) `
        -Message "Expected edit result success=true"

    $freeTaskPath = Join-Path $todoDir "task-free.json"
    $freeTask = Get-Content $freeTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "Edited task content is updated in todo file" `
        -Expected "Independent work updated" `
        -Actual $freeTask.description

    $historyAfterFirstEdit = Get-TaskVersionHistory -TaskId "task-free"
    Assert-Equal -Name "First edit creates one archived edited version" `
        -Expected 1 `
        -Actual @($historyAfterFirstEdit.edited_versions).Count
    Assert-Equal -Name "Edited archive stores previous content snapshot" `
        -Expected "Independent work" `
        -Actual $historyAfterFirstEdit.edited_versions[0].task.description
    Assert-Equal -Name "Edited archive stores actor metadata" `
        -Expected "dotbot-test" `
        -Actual $historyAfterFirstEdit.edited_versions[0].captured_by

    $secondEdit = Update-TaskContent -TaskId "task-free" -Actor "dotbot-test" -Updates @{
        description = "Independent work updated twice"
    }
    Assert-True -Name "Second Update-TaskContent returns success" `
        -Condition ($secondEdit.success -eq $true) `
        -Message "Expected second edit result success=true"

    $historyAfterSecondEdit = Get-TaskVersionHistory -TaskId "task-free"
    $originalSnapshot = @($historyAfterSecondEdit.edited_versions | Where-Object { $_.task.description -eq 'Independent work' }) | Select-Object -First 1
    Assert-True -Name "Second edit preserves original snapshot in history" `
        -Condition ($null -ne $originalSnapshot) `
        -Message "Expected to find original description in version history"

    $taskApiModule = Join-Path $botDir "core/ui/modules/TaskAPI.psm1"
    $taskApiImportWarnings = @()
    Import-Module $taskApiModule -Force -DisableNameChecking -WarningVariable taskApiImportWarnings
    Initialize-TaskAPI -BotRoot $botDir -ProjectRoot $testProject
    $roadmapActionsScript = Join-Path $botDir "core/ui/static/modules/roadmap-task-actions.js"
    $expectedAuditUsername = Get-ExpectedAuditUsername

    Assert-Equal -Name "TaskAPI imports cleanly when name checking is disabled" `
        -Expected 0 `
        -Actual @($taskApiImportWarnings).Count
    Assert-True -Name "TaskAPI exports Delete-RoadmapTask" `
        -Condition ($null -ne (Get-Command Delete-RoadmapTask -ErrorAction SilentlyContinue)) `
        -Message "Expected Delete-RoadmapTask to be exported"

    $structuredEditResult = Update-RoadmapTask -TaskId "task-object" -Actor "dotbot-test" -Updates @{
        description = "Structured task updated"
    }
    Assert-True -Name "TaskAPI Update-RoadmapTask edits structured task successfully" `
        -Condition ($structuredEditResult.success -eq $true) `
        -Message "Expected structured task edit to succeed"

    $invalidArchiveRecord = [ordered]@{
        version_id = [guid]::NewGuid().ToString()
        task_id = "task-object"
        archive_kind = "edit"
        source_status = "todo"
        source_file_name = "task-object.json"
        captured_at = "not-a-date"
        captured_by = "dotbot-test"
        task = [ordered]@{
            id = "task-object"
            name = "Structured task"
            description = "Broken timestamp snapshot"
        }
    }
    $invalidArchivePath = Join-Path (Join-Path $todoDir "edited_tasks") "task-object--invalid.json"
    $invalidArchiveRecord | ConvertTo-Json -Depth 20 | Set-Content -Path $invalidArchivePath -Encoding UTF8

    $structuredHistoryJson = Get-RoadmapTaskHistory -TaskId "task-object" | ConvertTo-Json -Depth 20
    $structuredHistory = $structuredHistoryJson | ConvertFrom-Json
    Assert-True -Name "TaskAPI history serializes structured tasks to JSON" `
        -Condition ($structuredHistory.success -eq $true) `
        -Message "Expected structured task history API to return success"
    Assert-True -Name "TaskAPI history tolerates invalid archive timestamps" `
        -Condition (@($structuredHistory.edited_versions).Count -ge 1) `
        -Message "Expected invalid archive timestamps not to break history API"

    $listEditResult = Update-RoadmapTask -TaskId "task-list-edit" -Actor "ui:test-profile" -Updates @{
        steps = @(
            "Read jira-context.md for context and search terms",
            "Discover repositories by searching for domain entities and API patterns"
        )
        acceptance_criteria = @(
            "All relevant repos identified",
            "Cross-repo dependencies mapped"
        )
    }
    Assert-True -Name "TaskAPI Update-RoadmapTask preserves string list edits" `
        -Condition ($listEditResult.success -eq $true) `
        -Message "Expected list edit result success=true"

    $listEditTaskPath = Join-Path $todoDir "task-list-edit.json"
    $listEditTask = Get-Content $listEditTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "Edited task keeps two implementation steps" `
        -Expected 2 `
        -Actual @($listEditTask.steps).Count
    Assert-True -Name "Edited task keeps implementation steps as strings" `
        -Condition (@($listEditTask.steps | Where-Object { $_ -is [string] }).Count -eq 2) `
        -Message "Expected implementation steps to remain string values"
    Assert-Equal -Name "Edited task stores first implementation step text" `
        -Expected "Read jira-context.md for context and search terms" `
        -Actual $listEditTask.steps[0]
    Assert-Equal -Name "Edited task stores first acceptance criterion text" `
        -Expected "All relevant repos identified" `
        -Actual $listEditTask.acceptance_criteria[0]
    Assert-Equal -Name "Edited task keeps actor context for list edits" `
        -Expected "ui:test-profile" `
        -Actual $listEditTask.updated_by
    Assert-Equal -Name "Edited task stores machine username for list edits" `
        -Expected $expectedAuditUsername `
        -Actual $listEditTask.updated_by_user

    $listEditHistory = Get-RoadmapTaskHistory -TaskId "task-list-edit"
    $latestListEditArchive = @($listEditHistory.edited_versions) | Select-Object -First 1
    Assert-True -Name "List edit creates an archived prior version" `
        -Condition ($null -ne $latestListEditArchive) `
        -Message "Expected list edit to create archived history"
    Assert-Equal -Name "Archived list edit keeps actor context" `
        -Expected "ui:test-profile" `
        -Actual $latestListEditArchive.captured_by
    Assert-Equal -Name "Archived list edit stores machine username" `
        -Expected $expectedAuditUsername `
        -Actual $latestListEditArchive.captured_by_user

    $serverScriptPath = Join-Path $botDir "core/ui/server.ps1"
    Assert-FileContains -Name "History route safely decodes encoded task IDs" `
        -Path $serverScriptPath `
        -Pattern 'UrlDecode\(\(\$url -replace "\^/api/task/history/", ""\)\)'
    Assert-FileContains -Name "Server imports TaskAPI with name checking disabled" `
        -Path $serverScriptPath `
        -Pattern 'Import-Module \(Join-Path \$PSScriptRoot "modules\\TaskAPI\.psm1"\) -Force -DisableNameChecking'
    Assert-FileContains -Name "Deleted archive UI renders RESTORED state" `
        -Path $roadmapActionsScript `
        -Pattern 'RESTORED'
    Assert-FileContains -Name "Deleted archive UI uses restore state flag" `
        -Path $roadmapActionsScript `
        -Pattern 'version\?\.is_restored === true'
    Assert-FileContains -Name "Deleted archive UI keeps restore action for active archive entries" `
        -Path $roadmapActionsScript `
        -Pattern 'const actionLabel = isRestored \? ''RESTORED'' : ''Restore'';'
    Assert-FileContains -Name "Roadmap task actions render machine username metadata" `
        -Path $roadmapActionsScript `
        -Pattern 'captured_by_user'
    Assert-FileContains -Name "Roadmap task actions listen for restore buttons by task-action attribute" `
        -Path $roadmapActionsScript `
        -Pattern 'closest\('\[data-task-action\]'\)'
    Assert-FileContains -Name "Roadmap task actions normalize ordinal dependency strings" `
        -Path $roadmapActionsScript `
        -Pattern 'function getRoadmapDependencyTokens'
    Assert-FileContains -Name "Roadmap task actions use roadmap-overview fallback dependencies" `
        -Path $roadmapActionsScript `
        -Pattern 'roadmap_dependencies'
    Assert-FileContains -Name "State builder surfaces roadmap-overview dependency data" `
        -Path (Join-Path $botDir "core/ui/modules/StateBuilder.psm1") `
        -Pattern 'roadmap_dependencies'
    Assert-FileContains -Name "State builder sorts roadmap tasks with deterministic tie-breakers" `
        -Path (Join-Path $botDir "core/ui/modules/StateBuilder.psm1") `
        -Pattern 'Sort-Object priority_num, name, id'
    $viewsCssPath = Join-Path $botDir "core/ui/static/css/views.css"
    Assert-FileContains -Name "Deleted archive uses a dedicated restore action" `
        -Path $roadmapActionsScript `
        -Pattern 'deleted-archive-action'
    Assert-FileContains -Name "Deleted archive footer keeps restore button visible" `
        -Path $viewsCssPath `
        -Pattern '\.deleted-archive-footer'
    Assert-FileContains -Name "Deleted archive action bar keeps dedicated restore button visible" `
        -Path $viewsCssPath `
        -Pattern '\.deleted-archive-action'
    Assert-FileContains -Name "Restored badge adds translucent highlight" `
        -Path $viewsCssPath `
        -Pattern '\.task-version-kind\.restored::after'

    $restoreEditResult = Restore-TaskVersion -TaskId "task-free" -VersionId $originalSnapshot.version_id -Actor "dotbot-test"
    Assert-True -Name "Restore-TaskVersion can restore an edited snapshot" `
        -Condition ($restoreEditResult.success -eq $true) `
        -Message "Expected restore result success=true for edited snapshot"

    $restoredTask = Get-Content $freeTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "Restoring an edited snapshot reverts task content" `
        -Expected "Independent work" `
        -Actual $restoredTask.description

    $deleteResult = Remove-TaskFromTodo -TaskId "task-free" -Actor "dotbot-test"
    Assert-True -Name "Remove-TaskFromTodo returns success" `
        -Condition ($deleteResult.success -eq $true) `
        -Message "Expected delete result success=true"
    Assert-PathNotExists -Name "Deleted task is removed from todo directory" -Path $freeTaskPath

    $historyAfterDelete = Get-TaskVersionHistory -TaskId "task-free"
    Assert-Equal -Name "Delete creates one archived deleted version" `
        -Expected 1 `
        -Actual @($historyAfterDelete.deleted_versions).Count

    $deletedSnapshot = $historyAfterDelete.deleted_versions[0]
    $restoreDeletedResult = Restore-TaskVersion -TaskId "task-free" -VersionId $deletedSnapshot.version_id -Actor "dotbot-test"
    Assert-True -Name "Restore-TaskVersion can restore a deleted snapshot" `
        -Condition ($restoreDeletedResult.success -eq $true) `
        -Message "Expected restore result success=true for deleted snapshot"
    Assert-PathExists -Name "Restoring deleted snapshot recreates todo task file" -Path $freeTaskPath

    $restoredDeletedTask = Get-Content $freeTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "Deleted snapshot restore preserves task description" `
        -Expected "Independent work" `
        -Actual $restoredDeletedTask.description

    $deletedArchiveAfterRestore = Get-DeletedRoadmapTasks
    $restoredArchiveEntry = @($deletedArchiveAfterRestore.deleted_versions | Where-Object { $_.version_id -eq $deletedSnapshot.version_id }) | Select-Object -First 1
    Assert-True -Name "Deleted archive marks restored task versions as restored" `
        -Condition ($null -ne $restoredArchiveEntry -and $restoredArchiveEntry.is_restored -eq $true) `
        -Message "Expected restored deleted archive entry to be marked restored"

    $deletedOnlyTaskPath = Join-Path $todoDir "task-deleted-only.json"
    $deletedOnlyDeleteResult = Remove-TaskFromTodo -TaskId "task-deleted-only" -Actor "dotbot-test"
    Assert-True -Name "Deleted-only task can be archived without prior edits" `
        -Condition ($deletedOnlyDeleteResult.success -eq $true) `
        -Message "Expected deleted-only task delete result success=true"
    Assert-PathNotExists -Name "Deleted-only task is removed from todo directory" -Path $deletedOnlyTaskPath

    $deletedOnlyHistory = Get-TaskVersionHistory -TaskId "task-deleted-only"
    Assert-Equal -Name "Deleted-only task has no edited archive history" `
        -Expected 0 `
        -Actual @($deletedOnlyHistory.edited_versions).Count
    Assert-Equal -Name "Deleted-only task has one deleted archive version" `
        -Expected 1 `
        -Actual @($deletedOnlyHistory.deleted_versions).Count

    $deletedOnlySnapshot = @($deletedOnlyHistory.deleted_versions)[0]
    $deletedArchiveBeforeRestore = Get-DeletedRoadmapTasks
    $deletedOnlyArchiveEntry = @($deletedArchiveBeforeRestore.deleted_versions | Where-Object { $_.version_id -eq $deletedOnlySnapshot.version_id }) | Select-Object -First 1
    Assert-True -Name "Deleted archive keeps non-restored task versions actionable" `
        -Condition ($null -ne $deletedOnlyArchiveEntry -and $deletedOnlyArchiveEntry.is_restored -eq $false) `
        -Message "Expected deleted-only archive entry to remain not restored before restore"
    $restoreDeletedOnlyResult = Restore-TaskVersion -TaskId "task-deleted-only" -VersionId $deletedOnlySnapshot.version_id -Actor "dotbot-test"
    Assert-True -Name "Restore-TaskVersion can restore a deleted-only snapshot" `
        -Condition ($restoreDeletedOnlyResult.success -eq $true) `
        -Message "Expected restore result success=true for deleted-only snapshot"
    Assert-PathExists -Name "Restoring deleted-only snapshot recreates todo task file" -Path $deletedOnlyTaskPath
}
finally {
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── Get-DeadlockedTasks tests ───────────────────────────────────────────────

$testProject = $null
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir      = Join-Path $tasksBaseDir "todo"
    $skippedDir   = Join-Path $tasksBaseDir "skipped"

    $taskIndexModule = Join-Path $botDir "core/mcp/modules/TaskIndexCache.psm1"
    Import-Module $taskIndexModule -Force

    # Verify export
    Assert-True -Name "TaskIndexCache exports Get-DeadlockedTasks" `
        -Condition ((Get-Command -Module TaskIndexCache).Name -contains 'Get-DeadlockedTasks') `
        -Message "Expected Get-DeadlockedTasks to be an exported function"

    # ── Scenario 1: No deadlock — no skipped tasks at all ──
    New-TestTaskFile -TasksTodoDir $todoDir `
        -TaskId "dl-free-1" -Name "Free task" `
        -Description "No dependencies" -Priority 10 | Out-Null

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $result1 = Get-DeadlockedTasks
    Assert-Equal -Name "No deadlock when no skipped tasks exist" `
        -Expected 0 -Actual $result1.BlockedCount

    # ── Scenario 2: Deadlock — todo task depends on a skipped task ──
    $skippedTask = [ordered]@{
        id = "dl-skipped-prereq"
        name = "Skipped prerequisite"
        description = "Was skipped"
        category = "feature"
        priority = 5
        effort = "S"
        status = "skipped"
        dependencies = @()
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    }
    $skippedTask | ConvertTo-Json -Depth 10 | Set-Content `
        -Path (Join-Path $skippedDir "dl-skipped-prereq.json") -Encoding UTF8

    # Add a todo task that depends on the skipped task
    New-TestTaskFile -TasksTodoDir $todoDir `
        -TaskId "dl-blocked-1" -Name "Blocked by skipped" `
        -Description "Depends on skipped prerequisite" -Priority 20 `
        -Dependencies @("dl-skipped-prereq") | Out-Null

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $result2 = Get-DeadlockedTasks
    Assert-Equal -Name "Deadlock detected: one todo task blocked by skipped prerequisite" `
        -Expected 1 -Actual $result2.BlockedCount
    Assert-True -Name "Deadlock reports correct blocker name" `
        -Condition ($result2.BlockerNames -contains "Skipped prerequisite") `
        -Message "Expected blocker name 'Skipped prerequisite', got: $($result2.BlockerNames -join ', ')"

    # ── Scenario 3: No deadlock — todo task has no deps (should not count) ──
    # dl-free-1 (no deps) is still in todo alongside dl-blocked-1 (blocked).
    # BlockedCount should still be 1, not 2.
    Assert-Equal -Name "Unblocked todo tasks are not counted as deadlocked" `
        -Expected 1 -Actual $result2.BlockedCount

    # ── Scenario 4: Dependency satisfied by done task — not a deadlock ──
    $doneTask = [ordered]@{
        id = "dl-skipped-prereq"
        name = "Skipped prerequisite"
        description = "Was skipped but then completed"
        category = "feature"
        priority = 5
        effort = "S"
        status = "done"
        dependencies = @()
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = "2026-03-06T13:00:00Z"
    }
    $doneDir = Join-Path $tasksBaseDir "done"
    $doneTask | ConvertTo-Json -Depth 10 | Set-Content `
        -Path (Join-Path $doneDir "dl-skipped-prereq.json") -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $result4 = Get-DeadlockedTasks
    Assert-Equal -Name "No deadlock when dependency is satisfied by done task" `
        -Expected 0 -Actual $result4.BlockedCount
}
finally {
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── task-get-next runtime condition evaluation (issue #226) ────────────────

$testProject = $null
$savedDotbotProjectRoot = $global:DotbotProjectRoot
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir      = Join-Path $tasksBaseDir "todo"
    $analysedDir  = Join-Path $tasksBaseDir "analysed"
    $skippedDir   = Join-Path $tasksBaseDir "skipped"

    $global:DotbotProjectRoot = $testProject

    # Load DotBotLog (normally provided by the MCP server) before dot-sourcing the tool.
    $dotBotLogModule = Join-Path $botDir "core/runtime/modules/DotBotLog.psm1"
    if (Test-Path $dotBotLogModule) {
        Import-Module $dotBotLogModule -Force -DisableNameChecking | Out-Null
        $tglLogsDir = Join-Path $botDir ".control\logs"
        $tglControlDir = Join-Path $botDir ".control"
        if (-not (Test-Path $tglLogsDir)) { New-Item -ItemType Directory -Path $tglLogsDir -Force | Out-Null }
        if (-not (Test-Path $tglControlDir)) { New-Item -ItemType Directory -Path $tglControlDir -Force | Out-Null }
        if (Get-Command Initialize-DotBotLog -ErrorAction SilentlyContinue) {
            Initialize-DotBotLog -LogDir $tglLogsDir -ControlDir $tglControlDir -ProjectRoot $testProject -ConsoleEnabled $false | Out-Null
        }
    }

    # Dot-source the tool script (not a module) so we can call Invoke-TaskGetNext directly.
    $taskGetNextScript = Join-Path $botDir "core/mcp/tools/task-get-next/script.ps1"
    Assert-PathExists -Name "task-get-next script exists in test project" -Path $taskGetNextScript
    . $taskGetNextScript

    Assert-True -Name "task-get-next dot-source exposes Invoke-TaskGetNext" `
        -Condition ($null -ne (Get-Command Invoke-TaskGetNext -ErrorAction SilentlyContinue)) `
        -Message "Expected Invoke-TaskGetNext to be defined after dot-sourcing task-get-next script"
    Assert-True -Name "task-get-next loads Test-ManifestCondition" `
        -Condition ($null -ne (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue)) `
        -Message "Expected Test-ManifestCondition to be imported from workflow-manifest.ps1"

    # ── Scenario A: unmet condition → task is auto-skipped ──
    $missingCondPath = Join-Path $todoDir "cond-missing.json"
    [ordered]@{
        id = "cond-missing"
        name = "Task with unmet condition"
        description = "Should be skipped at runtime"
        category = "feature"
        priority = 10
        effort = "S"
        status = "todo"
        dependencies = @()
        condition = ".bot/workspace/product/nonexistent.md"
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $missingCondPath -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    Update-TaskIndex

    $resultA = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false }
    Assert-True -Name "Invoke-TaskGetNext returns success when condition unmet" `
        -Condition ($resultA.success -eq $true) `
        -Message "Expected success=true, got: $($resultA | ConvertTo-Json -Depth 3)"
    Assert-True -Name "Invoke-TaskGetNext returns no task when only candidate has unmet condition" `
        -Condition ($null -eq $resultA.task) `
        -Message "Expected task=null, got: $($resultA.task | ConvertTo-Json -Depth 3)"

    $skippedFile = Join-Path $skippedDir "cond-missing.json"
    Assert-PathExists -Name "Task with unmet condition is moved to skipped/" -Path $skippedFile
    $skippedContent = Get-Content $skippedFile -Raw | ConvertFrom-Json
    Assert-Equal -Name "Skipped task has skip_reason=condition-not-met" `
        -Expected "condition-not-met" `
        -Actual $skippedContent.skip_reason
    Assert-Equal -Name "Skipped task has status=skipped" `
        -Expected "skipped" `
        -Actual $skippedContent.status

    $missingTodoGone = -not (Test-Path $missingCondPath)
    Assert-True -Name "Skipped task is removed from todo/" `
        -Condition $missingTodoGone `
        -Message "Expected todo file to be gone after skip"

    # ── Scenario B: condition met → task returned ──
    $productDir = Join-Path $botDir "workspace\product"
    if (-not (Test-Path $productDir)) {
        New-Item -ItemType Directory -Path $productDir -Force | Out-Null
    }
    Set-Content -Path (Join-Path $productDir "mission.md") -Value "test mission" -Encoding UTF8

    $metCondPath = Join-Path $todoDir "cond-met.json"
    [ordered]@{
        id = "cond-met"
        name = "Task with satisfied condition"
        description = "Should be returned at runtime"
        category = "feature"
        priority = 20
        effort = "S"
        status = "todo"
        dependencies = @()
        condition = ".bot/workspace/product/mission.md"
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $metCondPath -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    Update-TaskIndex

    $resultB = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false }
    Assert-True -Name "Invoke-TaskGetNext returns task when condition is met" `
        -Condition ($null -ne $resultB.task) `
        -Message "Expected task to be returned, got null. Message: $($resultB.message)"
    if ($resultB.task) {
        Assert-Equal -Name "Returned task is the one with satisfied condition" `
            -Expected "cond-met" `
            -Actual $resultB.task.id
    }
    Assert-PathExists -Name "Task with satisfied condition stays in todo/" -Path $metCondPath

    # Reset state for scenarios C and D.
    Get-ChildItem -Path $todoDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -Path $skippedDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force

    if (-not (Test-Path $productDir)) {
        New-Item -ItemType Directory -Path $productDir -Force | Out-Null
    }
    Set-Content -Path (Join-Path $productDir "mission.md") -Value "test mission for scenario C" -Encoding UTF8
    if (Test-Path (Join-Path $productDir "nope.md")) {
        Remove-Item (Join-Path $productDir "nope.md") -Force
    }

    # ── Scenario C: array condition (AND of rules) ──
    $arrayCondPath = Join-Path $todoDir "cond-array.json"
    [ordered]@{
        id = "cond-array"
        name = "Task with array condition"
        description = "AND of two rules"
        category = "feature"
        priority = 30
        effort = "S"
        status = "todo"
        dependencies = @()
        condition = @(
            ".bot/workspace/product/mission.md",
            "!.bot/workspace/product/nope.md"
        )
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $arrayCondPath -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    Update-TaskIndex

    $resultC1 = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false }
    Assert-True -Name "Array condition (all rules true) returns the task" `
        -Condition ($null -ne $resultC1.task -and $resultC1.task.id -eq 'cond-array') `
        -Message "Expected cond-array task to be returned. Got: $($resultC1.task.id)"
    Assert-PathExists -Name "Array-condition task stays in todo/ when all rules pass" -Path $arrayCondPath

    # Break the negated rule.
    Set-Content -Path (Join-Path $productDir "nope.md") -Value "boom" -Encoding UTF8
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    Update-TaskIndex

    $resultC2 = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false }
    Assert-True -Name "Array condition (one rule false) returns no task" `
        -Condition ($null -eq $resultC2.task) `
        -Message "Expected no task; got: $($resultC2.task | ConvertTo-Json -Depth 3)"
    Assert-PathExists -Name "Array-condition task moved to skipped/ when a rule fails" `
        -Path (Join-Path $skippedDir "cond-array.json")
    $arraySkipped = Get-Content (Join-Path $skippedDir "cond-array.json") -Raw | ConvertFrom-Json
    Assert-Equal -Name "Array-condition skipped task records skip_reason=condition-not-met" `
        -Expected "condition-not-met" `
        -Actual $arraySkipped.skip_reason

    Remove-Item (Join-Path $productDir "nope.md") -Force

    # ── Scenario D: analysed task with unmet condition (prefer_analysed=true) ──
    # The core issue path: re-evaluate condition at execution selection and move analysed → skipped.
    if (-not (Test-Path $analysedDir)) {
        New-Item -ItemType Directory -Path $analysedDir -Force | Out-Null
    }
    Get-ChildItem -Path $todoDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -Path $analysedDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem -Path $skippedDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force

    $analysedSkipPath = Join-Path $analysedDir "cond-analysed-skip.json"
    [ordered]@{
        id = "cond-analysed-skip"
        name = "Analysed task with unmet condition"
        description = "Should be moved analysed -> skipped at selection time"
        category = "feature"
        priority = 10
        effort = "S"
        status = "analysed"
        dependencies = @()
        condition = ".bot/workspace/product/never-created.md"
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $analysedSkipPath -Encoding UTF8

    $analysedKeepPath = Join-Path $analysedDir "cond-analysed-keep.json"
    [ordered]@{
        id = "cond-analysed-keep"
        name = "Analysed task with met condition"
        description = "Should be returned"
        category = "feature"
        priority = 20
        effort = "S"
        status = "analysed"
        dependencies = @()
        condition = ".bot/workspace/product/mission.md"
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $analysedKeepPath -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    Update-TaskIndex

    # Default prefer_analysed=true: skip cond-analysed-skip, return cond-analysed-keep.
    $resultD = Invoke-TaskGetNext -Arguments @{}
    Assert-True -Name "Analysed task with unmet condition is skipped, next analysed task is returned" `
        -Condition ($null -ne $resultD.task -and $resultD.task.id -eq 'cond-analysed-keep') `
        -Message "Expected cond-analysed-keep to be returned. Got: $($resultD.task.id); message: $($resultD.message)"
    Assert-Equal -Name "Returned analysed task carries status=analysed" `
        -Expected "analysed" `
        -Actual $resultD.task.status

    $analysedSkipDest = Join-Path $skippedDir "cond-analysed-skip.json"
    Assert-PathExists -Name "Analysed task with unmet condition moved to skipped/" -Path $analysedSkipDest
    Assert-True -Name "Analysed-skip task no longer in analysed/" `
        -Condition (-not (Test-Path $analysedSkipPath)) `
        -Message "Expected analysed/ source file to be removed after Set-TaskState"
    $analysedSkipped = Get-Content $analysedSkipDest -Raw | ConvertFrom-Json
    Assert-Equal -Name "Analysed→skipped task records skip_reason=condition-not-met" `
        -Expected "condition-not-met" `
        -Actual $analysedSkipped.skip_reason
}
finally {
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
    $global:DotbotProjectRoot = $savedDotbotProjectRoot
}

$allPassed = Write-TestSummary -LayerName "Task Action Source Tests"

if (-not $allPassed) {
    exit 1
}







