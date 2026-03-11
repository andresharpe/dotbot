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

    Copy-Item -Path (Join-Path $RepoRoot "profiles\default\*") -Destination $botDir -Recurse -Force

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

    $settingsPath = Join-Path $botDir "defaults\settings.default.json"
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
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity -and $identity.Name) {
            return $identity.Name
        }
    } catch {
        # Fall back to environment variables when Windows identity is unavailable.
    }

    if ($env:USERDOMAIN -and $env:USERNAME) {
        return "$($env:USERDOMAIN)\$($env:USERNAME)"
    }

    if ($env:USERNAME) {
        return $env:USERNAME
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

    $taskMutationModule = Join-Path $botDir "systems\mcp\modules\TaskMutation.psm1"
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

    $taskIndexModule = Join-Path $botDir "systems\mcp\modules\TaskIndexCache.psm1"
    Import-Module $taskIndexModule -Force
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
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

    $taskApiModule = Join-Path $botDir "systems\ui\modules\TaskAPI.psm1"
    Import-Module $taskApiModule -Force
    Initialize-TaskAPI -BotRoot $botDir -ProjectRoot $testProject
    $roadmapActionsScript = Join-Path $botDir "systems\ui\static\modules\roadmap-task-actions.js"
    $expectedAuditUsername = Get-ExpectedAuditUsername

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

    $serverScriptPath = Join-Path $botDir "systems\ui\server.ps1"
    Assert-FileContains -Name "History route safely decodes encoded task IDs" `
        -Path $serverScriptPath `
        -Pattern 'UrlDecode\(\(\$url -replace "\^/api/task/history/", ""\)\)'
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
        -Path (Join-Path $botDir "systems\ui\modules\StateBuilder.psm1") `
        -Pattern 'roadmap_dependencies'
    Assert-FileContains -Name "State builder sorts roadmap tasks with deterministic tie-breakers" `
        -Path (Join-Path $botDir "systems\ui\modules\StateBuilder.psm1") `
        -Pattern 'Sort-Object priority_num, name, id'
    $viewsCssPath = Join-Path $botDir "systems\ui\static\css\views.css"
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

    $taskIndexModule = Join-Path $botDir "systems\mcp\modules\TaskIndexCache.psm1"
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

$allPassed = Write-TestSummary -LayerName "Task Action Source Tests"

if (-not $allPassed) {
    exit 1
}








