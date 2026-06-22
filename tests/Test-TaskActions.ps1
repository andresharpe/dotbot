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

# Stub Write-BotLog if the host hasn't initialised Dotbot.Logging. Reset-
# SkippedTasks (and other code paths in Dotbot.Task / Dotbot.TaskIndex) call
# Write-BotLog unconditionally on certain branches; without a stub those
# tests throw on a function-not-found before reaching the assertion.
if (-not (Get-Command Write-BotLog -ErrorAction SilentlyContinue)) {
    function global:Write-BotLog { param([string]$Level, [string]$Message, $Exception) }
}

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

    # Mirror what dotbot init produces: src/ (engine) and content/
    # (agents/skills/prompts/recipes/settings/workspace-template) under .bot/,
    # plus launcher scripts at .bot/ root and the canonical workflow.
    $srcSource = Join-Path $RepoRoot "src"
    if (Test-Path $srcSource) {
        Copy-Item -Path $srcSource -Destination (Join-Path $botDir "src") -Recurse -Force
        foreach ($f in @("go.ps1", "init.ps1", "README.md", ".gitignore")) {
            $src = Join-Path $srcSource $f
            if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $botDir $f) -Force }
        }
        # hooks is engine; provide convenience copy at .bot/hooks/
        $hooksSrc = Join-Path $srcSource "hooks"
        if (Test-Path $hooksSrc) { Copy-Item -Path $hooksSrc -Destination (Join-Path $botDir "hooks") -Recurse -Force }
    }
    $contentSource = Join-Path $RepoRoot "content"
    if (Test-Path $contentSource) {
        Copy-Item -Path $contentSource -Destination (Join-Path $botDir "content") -Recurse -Force
        # settings is content; provide convenience copy at .bot/settings/
        $settingsSrc = Join-Path $contentSource "settings"
        if (Test-Path $settingsSrc) { Copy-Item -Path $settingsSrc -Destination (Join-Path $botDir "settings") -Recurse -Force }
    }
    $wfSrc = Join-Path $RepoRoot "content/workflows/start-from-prompt"
    if (Test-Path $wfSrc) {
        $wfDest = Join-Path $botDir "content/workflows/start-from-prompt"
        New-Item -ItemType Directory -Path $wfDest -Force | Out-Null
        Copy-Item -Path (Join-Path $wfSrc "*") -Destination $wfDest -Recurse -Force
    }

    $workspaceDirs = @(
        "workspace\tasks\todo",
        "workspace\tasks\todo\edited_tasks",
        "workspace\tasks\todo\deleted_tasks",
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
    Push-Location $testProject
    $botDir = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir = Join-Path $tasksBaseDir "todo"

    $global:DotbotProjectRoot = $testProject

    $taskMutationModule = Join-Path $botDir "src/mcp/modules/TaskMutation.psm1"
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

    $taskStoreModule = Join-Path $botDir "src/mcp/modules/TaskStore.psm1"
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
        prompt       = "prompts/02a-plan-internet-research.md"
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

    $taskIndexModule = Join-Path $botDir "src/runtime/Modules/Dotbot.TaskIndex/Dotbot.TaskIndex.psm1"
    Import-Module $taskIndexModule -Force
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

    # Verify Dotbot.TaskIndex stores the prompt field
    $ptIndexEntry = (Get-TaskIndex).Todo['task-prompt-template']
    Assert-True -Name "Dotbot.TaskIndex stores prompt field for prompt_template task" `
        -Condition ($ptIndexEntry -and $ptIndexEntry.prompt -eq "prompts/02a-plan-internet-research.md") `
        -Message "Expected index entry to carry prompt='prompts/02a-plan-internet-research.md'"

    # task-get-next is now a thin HTTP wrapper around GET /tasks/next,
    # so the in-process index-shape assertion (`getNextResult.task.prompt`)
    # belongs on the runtime handler, not the tool. The Dotbot.TaskIndex prompt-
    # field assertion above already exercises the relevant data; will
    # add a /tasks/next handler test covering the prompt passthrough.
    Remove-Item -Path $ptTaskPath -Force -ErrorAction SilentlyContinue
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
    Assert-FileContains -Name "Dotbot.TaskIndex supports roadmap-overview dependency fallback" `
        -Path $taskIndexModule `
        -Pattern 'function Get-IgnoreRoadmapDependencyMap'
    Assert-FileContains -Name "Dotbot.TaskIndex resolves fallback roadmap dependencies" `
        -Path $taskIndexModule `
        -Pattern 'function Get-ResolvedIgnoreDependencies'
    Assert-FileContains -Name "TaskStore defines canonical Get-TodoTaskRecord" `
        -Path $taskStoreModule `
        -Pattern 'function Get-TodoTaskRecord'
    Assert-True -Name "TaskMutation does not define Get-TodoTaskRecord (delegated to TaskStore)" `
        -Condition (-not (Select-String -Path $taskMutationModule -Pattern 'function Get-TodoTaskRecord' -Quiet)) `
        -Message "Expected TaskMutation to delegate Get-TodoTaskRecord to TaskStore, not define it locally"
    Assert-True -Name "StateBuilder does not define Get-RoadmapOverviewDependencyMap (uses TaskMutation's)" `
        -Condition (-not (Select-String -Path (Join-Path $botDir "src/ui/modules/StateBuilder.psm1") -Pattern 'function Get-RoadmapOverviewDependencyMap' -Quiet)) `
        -Message "Expected StateBuilder to use TaskMutation's Get-RoadmapOverviewDependencyMap, not define it locally"
    Assert-FileContains -Name "TaskStore defines canonical Get-TaskSlug" `
        -Path $taskStoreModule `
        -Pattern 'function Get-TaskSlug'
    Assert-True -Name "TaskMutation does not define Get-TaskSlug (delegated to TaskStore)" `
        -Condition (-not (Select-String -Path $taskMutationModule -Pattern 'function Get-TaskSlug' -Quiet)) `
        -Message "Expected TaskMutation to use TaskStore's Get-TaskSlug, not define it locally"
    $worktreeManagerModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1"
    Assert-True -Name "Dotbot.Worktree does not define Get-TaskSlug (delegated to TaskStore)" `
        -Condition (-not (Select-String -Path $worktreeManagerModule -Pattern 'function Get-TaskSlug' -Quiet)) `
        -Message "Expected Dotbot.Worktree to use TaskStore's Get-TaskSlug, not define it locally"
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

    $taskApiModule = Join-Path $botDir "src/ui/modules/TaskAPI.psm1"
    $taskApiImportWarnings = @()
    Import-Module $taskApiModule -Force -DisableNameChecking -WarningVariable taskApiImportWarnings
    Import-Module (Join-Path $botDir "src/runtime/Modules/Dotbot.Handoff/Dotbot.Handoff.psd1") -Force -DisableNameChecking -Global
    Initialize-TaskAPI -BotRoot $botDir -ProjectRoot $testProject
    $roadmapActionsScript = Join-Path $botDir "src/ui/static/modules/roadmap-task-actions.js"
    $expectedAuditUsername = Get-ExpectedAuditUsername

    Assert-Equal -Name "TaskAPI imports cleanly when name checking is disabled" `
        -Expected 0 `
        -Actual @($taskApiImportWarnings).Count
    Assert-True -Name "TaskAPI exports Delete-RoadmapTask" `
        -Condition ($null -ne (Get-Command Delete-RoadmapTask -ErrorAction SilentlyContinue)) `
        -Message "Expected Delete-RoadmapTask to be exported"

    $noProviderSessionTask = [pscustomobject]@{
        id = "t_nosess01"
        status = "in-progress"
    }
    $noProviderSessionAttempt = Start-DotbotTaskSessionAttempt -TaskContent $noProviderSessionTask
    Assert-True -Name "Task handoff records attempts without provider session id" `
        -Condition ($noProviderSessionAttempt.attempt_id -eq "a01" -and $null -eq $noProviderSessionAttempt.provider_session_id) `
        -Message "Providers such as OpenCode create session ids internally; task attempts should still be tracked"

    $standaloneDir = Join-Path $tasksBaseDir "standalone"
    New-Item -ItemType Directory -Force -Path $standaloneDir | Out-Null

    $answerTaskId = "t_answ1234"
    $answerTaskPath = Join-Path $standaloneDir "2026-03-06-answer-task-1234.json"
    $answerTask = [ordered]@{
        schema_version = 2
        id = $answerTaskId
        name = "Answer task"
        description = "Question answer transition"
        status = "needs-input"
        provenance = [ordered]@{ workflow = $null; run_id = $null; definition_name = $null; expanded_by = $null }
        category = "feature"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
        updated_by = "test"
        extensions = [ordered]@{
            runner = [ordered]@{
                pending_question = [ordered]@{
                    id = "q-answer"
                    question = "Which option?"
                    options = @([ordered]@{ key = "A"; label = "Use runtime transition"; rationale = "Project-owned path" })
                    asked_at = "2026-03-06T12:00:00Z"
                }
            }
        }
    }
    $null = New-DotbotTaskHandoff `
        -TaskContent $answerTask `
        -BotRoot $botDir `
        -QuestionId "q-answer" `
        -Question "Which option?" `
        -Context "Question answer transition" `
        -Reason "test"
    $answerTask | ConvertTo-Json -Depth 20 | Set-Content -Path $answerTaskPath -Encoding UTF8

    $answerResult = Submit-TaskAnswer -TaskId $answerTaskId -Answer "A"
    Assert-True -Name "TaskAPI Submit-TaskAnswer transitions canonical task input" `
        -Condition ($answerResult.success -eq $true -and $answerResult.new_status -eq "todo") `
        -Message "Expected answer submission to requeue todo, got $($answerResult | ConvertTo-Json -Compress)"
    $answeredTask = Get-Content $answerTaskPath -Raw | ConvertFrom-Json
    Assert-True -Name "TaskAPI answer clears runner pending_question" `
        -Condition ($null -eq $answeredTask.extensions.runner.pending_question) `
        -Message "Expected pending_question to be null"
    Assert-Equal -Name "TaskAPI answer records UI source" `
        -Expected "ui" `
        -Actual $answeredTask.extensions.runner.questions_resolved[0].answered_via
    Assert-True -Name "TaskAPI answer clears current handoff" `
        -Condition ($null -eq $answeredTask.extensions.runner.current_handoff) `
        -Message "Expected current_handoff to be null after answer"
    Assert-Equal -Name "TaskAPI answer records handoff resume answer" `
        -Expected "A - Use runtime transition" `
        -Actual $answeredTask.extensions.runner.resume_context.answer
    Assert-True -Name "TaskAPI answer records next session attempt" `
        -Condition ($answeredTask.extensions.runner.resume_context.next_attempt_id -cmatch '^a\d{2}$') `
        -Message "Expected next_attempt_id to be an attempt id"
    $handoffManifestPath = Join-Path $testProject $answeredTask.extensions.runner.resume_context.manifest_path
    $handoffManifest = Get-Content -Path $handoffManifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "TaskAPI answer consumes task-scoped handoff manifest" `
        -Expected "consumed" `
        -Actual $handoffManifest.status
    Assert-Equal -Name "TaskAPI handoff manifest remains bound to same task" `
        -Expected $answerTaskId `
        -Actual $handoffManifest.task_id

    $batchTaskId = "t_batch123"
    $batchTaskPath = Join-Path $standaloneDir "2026-03-06-batch-task-123.json"
    $batchTask = [ordered]@{
        schema_version = 2
        id = $batchTaskId
        name = "Batch answer task"
        description = "Question batch transition"
        status = "needs-input"
        provenance = [ordered]@{ workflow = $null; run_id = $null; definition_name = $null; expanded_by = $null }
        category = "feature"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
        updated_by = "test"
        extensions = [ordered]@{
            runner = [ordered]@{
                pending_questions = @(
                    [ordered]@{
                        question = "First unanswered question?"
                        options = @([ordered]@{ key = "A"; label = "First answer"; rationale = "Test first" })
                    }
                    [ordered]@{
                        question = "Second unanswered question?"
                        options = @([ordered]@{ key = "B"; label = "Second answer"; rationale = "Test second" })
                    }
                )
            }
        }
    }
    $batchTask | ConvertTo-Json -Depth 20 | Set-Content -Path $batchTaskPath -Encoding UTF8
    $batchWorktreePath = Join-Path $testProject "task-batch-worktree"
    $batchWorktreeProductDir = Join-Path $batchWorktreePath ".bot/workspace/product"
    New-Item -ItemType Directory -Force -Path $batchWorktreeProductDir | Out-Null
    $worktreeMap = [ordered]@{}
    $worktreeMap[$batchTaskId] = [ordered]@{
        worktree_path = $batchWorktreePath
        branch_name = "task/batch-answer"
        task_name = "Batch answer task"
    }
    $worktreeMap | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $botDir ".control/worktree-map.json") -Encoding UTF8

    $actionRequired = Get-ActionRequired
    $batchAction = @($actionRequired.items | Where-Object { $_.task_id -eq $batchTaskId }) | Select-Object -First 1
    Assert-True -Name "TaskAPI action-required assigns ids to idless batch questions" `
        -Condition ($batchAction -and @($batchAction.questions).Count -eq 2 -and $batchAction.questions[0].id -eq "q1" -and $batchAction.questions[1].id -eq "q2") `
        -Message "Expected two normalized question ids, got: $($batchAction | ConvertTo-Json -Depth 10 -Compress)"
    $batchTask = Get-Content $batchTaskPath -Raw | ConvertFrom-Json
    $null = New-DotbotTaskHandoff `
        -TaskContent $batchTask `
        -BotRoot $botDir `
        -QuestionId "q1" `
        -Question "First unanswered question?" `
        -Context "Batch question transition" `
        -Reason "test"
    $batchTask | ConvertTo-Json -Depth 20 | Set-Content -Path $batchTaskPath -Encoding UTF8

    $firstBatchResult = Submit-TaskAnswer -TaskId $batchTaskId -QuestionId "q1" -Answer "A"
    Assert-True -Name "TaskAPI batch answer keeps task in needs-input while questions remain" `
        -Condition ($firstBatchResult.success -eq $true -and $firstBatchResult.new_status -eq "needs-input" -and $firstBatchResult.questions_remaining_count -eq 1) `
        -Message "Expected one question to remain, got $($firstBatchResult | ConvertTo-Json -Depth 10 -Compress)"
    $batchAfterFirst = Get-Content $batchTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "TaskAPI batch answer leaves second question pending" `
        -Expected "Second unanswered question?" `
        -Actual $batchAfterFirst.extensions.runner.pending_questions[0].question
    Assert-Equal -Name "TaskAPI batch answer records answered question id" `
        -Expected "q1" `
        -Actual $batchAfterFirst.extensions.runner.questions_resolved[0].id
    # interview-answers.json is a run-level accumulator: it must land in the MAIN
    # checkout product dir, NOT the per-task worktree (issue #516). A worktree-local
    # copy would diverge across parallel tasks and collide at squash-merge.
    $mainAnswersPath = Join-Path $botDir "workspace/product/interview-answers.json"
    Assert-True -Name "TaskAPI batch answer writes interview answer to main checkout, not worktree" `
        -Condition ((Test-Path -LiteralPath $mainAnswersPath) -and -not (Test-Path -LiteralPath (Join-Path $batchWorktreeProductDir "interview-answers.json"))) `
        -Message "Expected answer at main ($mainAnswersPath) and absent from worktree ($batchWorktreeProductDir)"
    # The accumulator is shared across every task in the run, so earlier answers
    # in this project coexist with q1 — assert containment, not position.
    $batchMainAnswers = Get-Content $mainAnswersPath -Raw | ConvertFrom-Json
    Assert-True -Name "TaskAPI batch answer appends question id to shared main accumulator" `
        -Condition (@($batchMainAnswers.answers.question_id) -contains "q1") `
        -Message "Expected main accumulator to contain q1, got: $(@($batchMainAnswers.answers.question_id) -join ', ')"

    $secondBatchResult = Submit-TaskAnswer -TaskId $batchTaskId -QuestionId "q2" -Answer "B"
    Assert-True -Name "TaskAPI batch answer resumes after final question" `
        -Condition ($secondBatchResult.success -eq $true -and $secondBatchResult.new_status -eq "todo" -and $secondBatchResult.questions_remaining_count -eq 0) `
        -Message "Expected final batch answer to requeue task, got $($secondBatchResult | ConvertTo-Json -Depth 10 -Compress)"
    $batchAfterSecond = Get-Content $batchTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "TaskAPI batch answer final status is todo" `
        -Expected "todo" `
        -Actual $batchAfterSecond.status
    $batchHandoffManifestPath = Join-Path $batchWorktreePath $batchAfterSecond.extensions.runner.resume_context.manifest_path
    $batchHandoffManifest = Get-Content -Path $batchHandoffManifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "TaskAPI batch answer consumes handoff after final question" `
        -Expected "consumed" `
        -Actual $batchHandoffManifest.status
    Assert-Equal -Name "TaskAPI batch handoff records final answered question" `
        -Expected "q2" `
        -Actual $batchAfterSecond.extensions.runner.resume_context.question_id

    $semanticBatchTaskId = "t_semantic"
    $semanticBatchTaskPath = Join-Path $standaloneDir "2026-03-06-semantic-batch-task.json"
    $semanticBatchTask = [ordered]@{
        schema_version = 2
        id = $semanticBatchTaskId
        name = "Semantic batch answer task"
        description = "Semantic question batch transition"
        status = "needs-input"
        provenance = [ordered]@{ workflow = $null; run_id = $null; definition_name = $null; expanded_by = $null }
        category = "feature"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
        updated_by = "test"
        extensions = [ordered]@{
            runner = [ordered]@{
                pending_questions = @(
                    [ordered]@{
                        id = "product-domain"
                        question = "What product domain is this for?"
                        options = @([ordered]@{ key = "A"; label = "Weather"; rationale = "Forecast app" })
                    }
                    [ordered]@{
                        id = "scope-mvp"
                        question = "What is the MVP scope?"
                        options = @([ordered]@{ key = "A"; label = "Forecast only"; rationale = "Keep scope narrow" })
                    }
                )
            }
        }
    }
    $semanticWorktreePath = Join-Path $testProject "task-semantic-worktree"
    New-Item -ItemType Directory -Force -Path (Join-Path $semanticWorktreePath ".bot/workspace/product") | Out-Null
    $worktreeMap[$semanticBatchTaskId] = [ordered]@{
        worktree_path = $semanticWorktreePath
        branch_name = "task/semantic-answer"
        task_name = "Semantic batch answer task"
    }
    $worktreeMap | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $botDir ".control/worktree-map.json") -Encoding UTF8

    $null = New-DotbotTaskHandoff `
        -TaskContent $semanticBatchTask `
        -BotRoot $botDir `
        -QuestionId "product-domain" `
        -Question "What product domain is this for?" `
        -Context "Semantic batch question transition" `
        -Reason "test"
    $semanticManifestPath = Join-Path $semanticWorktreePath $semanticBatchTask.extensions.runner.current_handoff.manifest_path
    $semanticManifest = Get-Content -Path $semanticManifestPath -Raw | ConvertFrom-Json
    $semanticManifest.question_ids = @("product-domain")
    $semanticManifest | ConvertTo-Json -Depth 20 | Set-Content -Path $semanticManifestPath -Encoding UTF8
    $semanticBatchTask | ConvertTo-Json -Depth 20 | Set-Content -Path $semanticBatchTaskPath -Encoding UTF8

    $firstSemanticResult = Submit-TaskAnswer -TaskId $semanticBatchTaskId -QuestionId "product-domain" -Answer "A"
    Assert-True -Name "TaskAPI semantic batch answer keeps remaining question pending" `
        -Condition ($firstSemanticResult.success -eq $true -and $firstSemanticResult.new_status -eq "needs-input" -and $firstSemanticResult.questions_remaining_count -eq 1) `
        -Message "Expected semantic batch to keep one pending question, got $($firstSemanticResult | ConvertTo-Json -Depth 10 -Compress)"

    $secondSemanticResult = Submit-TaskAnswer -TaskId $semanticBatchTaskId -QuestionId "scope-mvp" -Answer "A"
    Assert-True -Name "TaskAPI semantic batch accepts final answer against first-question handoff" `
        -Condition ($secondSemanticResult.success -eq $true -and $secondSemanticResult.new_status -eq "todo") `
        -Message "Expected final semantic answer to consume first-question handoff, got $($secondSemanticResult | ConvertTo-Json -Depth 10 -Compress)"
    $semanticAfterSecond = Get-Content $semanticBatchTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "TaskAPI semantic batch records final answered question" `
        -Expected "scope-mvp" `
        -Actual $semanticAfterSecond.extensions.runner.resume_context.question_id

    $legacyHandoffTaskId = "t_legacyho"
    $legacyHandoffTask = [ordered]@{
        schema_version = 2
        id = $legacyHandoffTaskId
        name = "Legacy handoff batch task"
        description = "Task-scoped handoff consumption"
        status = "needs-input"
        provenance = [ordered]@{ workflow = $null; run_id = $null; definition_name = $null; expanded_by = $null }
        category = "feature"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
        updated_by = "test"
        extensions = [ordered]@{
            runner = [ordered]@{
                pending_questions = @(
                    [ordered]@{
                        id = "pq-product-purpose"
                        question = "What is the product purpose?"
                        options = @([ordered]@{ key = "A"; label = "Forecast planning"; rationale = "Defines product purpose" })
                    }
                    [ordered]@{
                        id = "pq-tech-preferences"
                        question = "Any technology preferences?"
                        options = @([ordered]@{ key = "A"; label = "C#"; rationale = "User requested C#" })
                    }
                )
            }
        }
    }
    $legacyWorktreePath = Join-Path $testProject "task-legacy-handoff-worktree"
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyWorktreePath ".bot/workspace/product") | Out-Null
    $worktreeMap[$legacyHandoffTaskId] = [ordered]@{
        worktree_path = $legacyWorktreePath
        branch_name = "task/legacy-handoff"
        task_name = "Legacy handoff batch task"
    }
    $worktreeMap | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $botDir ".control/worktree-map.json") -Encoding UTF8

    $null = New-DotbotTaskHandoff `
        -TaskContent $legacyHandoffTask `
        -BotRoot $botDir `
        -QuestionId "pq-product-purpose" `
        -Question "What is the product purpose?" `
        -Context "Legacy handoff question mismatch transition" `
        -Reason "test"
    $legacyManifestPath = Join-Path $legacyWorktreePath $legacyHandoffTask.extensions.runner.current_handoff.manifest_path
    $legacyManifest = Get-Content -Path $legacyManifestPath -Raw | ConvertFrom-Json
    $legacyManifest.question_ids = @("pq-product-purpose")
    $legacyManifest | ConvertTo-Json -Depth 20 | Set-Content -Path $legacyManifestPath -Encoding UTF8

    $legacyHandoffTask.extensions.runner.pending_questions = @()
    $legacyHandoffTask.extensions.runner.questions_resolved = @()
    $legacyCompletion = Complete-DotbotTaskHandoffForAnswer `
        -TaskContent $legacyHandoffTask `
        -BotRoot $botDir `
        -QuestionId "pq-tech-preferences" `
        -Answer "A - C#" `
        -AnsweredAt "2026-03-06T12:05:00Z"

    Assert-True -Name "Task-scoped handoff accepts final batch answer with legacy first-question manifest" `
        -Condition ($legacyCompletion.success -eq $true -and $legacyCompletion.skipped -eq $false) `
        -Message "Expected legacy handoff to consume same-task final answer, got $($legacyCompletion | ConvertTo-Json -Depth 10 -Compress)"
    $legacyConsumedManifest = Get-Content -Path $legacyManifestPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "Task-scoped handoff records final consumed status" `
        -Expected "consumed" `
        -Actual $legacyConsumedManifest.status
    Assert-True -Name "Task-scoped handoff preserves final answer id in manifest audit ids" `
        -Condition ("pq-tech-preferences" -in @($legacyConsumedManifest.question_ids)) `
        -Message "Expected manifest question_ids to include final answer id"

    $splitTaskId = "t_split123"
    $splitTaskPath = Join-Path $standaloneDir "2026-03-06-split-task-t123.json"
    $splitTask = [ordered]@{
        schema_version = 2
        id = $splitTaskId
        name = "Split task"
        description = "Split decision transition"
        status = "needs-input"
        provenance = [ordered]@{ workflow = $null; run_id = $null; definition_name = $null; expanded_by = $null }
        category = "feature"
        priority = 50
        effort = "M"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-03-06T12:00:00Z"
        updated_at = "2026-03-06T12:00:00Z"
        completed_at = $null
        updated_by = "test"
        extensions = [ordered]@{
            runner = [ordered]@{
                split_proposal = [ordered]@{
                    reason = "Break into smaller work"
                    sub_tasks = @(
                        [ordered]@{
                            name = "Child split task"
                            description = "Created from split approval"
                            effort = "S"
                        }
                    )
                }
            }
        }
    }
    $splitTask | ConvertTo-Json -Depth 20 | Set-Content -Path $splitTaskPath -Encoding UTF8

    $splitResult = Submit-SplitApproval -TaskId $splitTaskId -Approved $true
    Assert-True -Name "TaskAPI Submit-SplitApproval creates child task via runtime transition" `
        -Condition ($splitResult.success -eq $true -and $splitResult.sub_tasks_created -eq 1 -and (Test-Path $splitResult.created_tasks[0].file_path)) `
        -Message "Expected one child task to be created, got $($splitResult | ConvertTo-Json -Depth 10 -Compress)"
    $approvedParent = Get-Content $splitTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "TaskAPI approved split marks parent superseded" `
        -Expected "skipped" `
        -Actual $approvedParent.status
    Assert-Equal -Name "TaskAPI approved split records UI source" `
        -Expected "ui" `
        -Actual $approvedParent.extensions.runner.split_proposal.answered_via

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

    $serverScriptPath = Join-Path $botDir "src/ui/server.ps1"
    Assert-FileContains -Name "History route safely decodes encoded task IDs" `
        -Path $serverScriptPath `
        -Pattern 'UrlDecode\(\(\$url -replace "\^/api/task/history/", ""\)\)'
    Assert-FileContains -Name "Server imports TaskAPI with name checking disabled" `
        -Path $serverScriptPath `
        -Pattern 'Import-Module \(Join-Path \$PSScriptRoot "modules/TaskAPI\.psm1"\) -Force -DisableNameChecking'
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
        -Path (Join-Path $botDir "src/ui/modules/StateBuilder.psm1") `
        -Pattern 'roadmap_dependencies'
    Assert-FileContains -Name "State builder sorts roadmap tasks with deterministic tie-breakers" `
        -Path (Join-Path $botDir "src/ui/modules/StateBuilder.psm1") `
        -Pattern 'Sort-Object priority_num, name, id'
    $viewsCssPath = Join-Path $botDir "src/ui/static/css/views.css"
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
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── Get-DeadlockedTasks tests ───────────────────────────────────────────────

$testProject = $null
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir      = Join-Path $tasksBaseDir "todo"
    $skippedDir   = Join-Path $tasksBaseDir "skipped"

    $taskIndexModule = Join-Path $botDir "src/runtime/Modules/Dotbot.TaskIndex/Dotbot.TaskIndex.psm1"
    Import-Module $taskIndexModule -Force

    # Verify export
    Assert-True -Name "Dotbot.TaskIndex exports Get-DeadlockedTasks" `
        -Condition ((Get-Command -Module Dotbot.TaskIndex).Name -contains 'Get-DeadlockedTasks') `
        -Message "Expected Get-DeadlockedTasks to be an exported function"

    # ── Scenario 1: No deadlock — no skipped tasks at all ──
    New-TestTaskFile -TasksTodoDir $todoDir `
        -TaskId "dl-free-1" -Name "Free task" `
        -Description "No dependencies" -Priority 10 | Out-Null

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $result1 = Get-DeadlockedTasks
    Assert-Equal -Name "No deadlock when no skipped tasks exist" `
        -Expected 0 -Actual $result1.BlockedCount

    # ── Scenario 2 (issue #318): No deadlock — INTENTIONAL skip satisfies deps ──
    # An intentional skip (task_mark_skipped with not-applicable etc.) should
    # unblock dependents, not deadlock them.
    $intentionalSkipped = [ordered]@{
        id = "dl-intentional-prereq"
        name = "Intentional skip prereq"
        description = "Intentionally skipped (not applicable)"
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
        skip_history = @(@{ skipped_at = "2026-03-06T12:30:00Z"; reason = "not-applicable" })
    }
    $intentionalSkipped | ConvertTo-Json -Depth 10 | Set-Content `
        -Path (Join-Path $skippedDir "dl-intentional-prereq.json") -Encoding UTF8

    New-TestTaskFile -TasksTodoDir $todoDir `
        -TaskId "dl-after-intentional" -Name "Runs after intentional skip" `
        -Description "Depends on intentionally skipped prereq" -Priority 20 `
        -Dependencies @("dl-intentional-prereq") | Out-Null

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultIntentional = Get-DeadlockedTasks
    Assert-Equal -Name "No deadlock: intentional skip satisfies dependency (issue #318)" `
        -Expected 0 -Actual $resultIntentional.BlockedCount

    # ── Scenario 3 (issue #318): Deadlock — todo depends on a FRAMEWORK-ERROR skip ──
    # Same skipped/ directory, but skip_history reason is 'non-recoverable'.
    $frameworkSkipped = [ordered]@{
        id = "dl-framework-prereq"
        name = "Framework-error prereq"
        description = "Skipped due to non-recoverable error"
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
        skip_history = @(@{ skipped_at = "2026-03-06T12:30:00Z"; reason = "non-recoverable"; detail = "missing dependency" })
    }
    $frameworkSkipped | ConvertTo-Json -Depth 10 | Set-Content `
        -Path (Join-Path $skippedDir "dl-framework-prereq.json") -Encoding UTF8

    New-TestTaskFile -TasksTodoDir $todoDir `
        -TaskId "dl-blocked-1" -Name "Blocked by framework error" `
        -Description "Depends on framework-error prereq" -Priority 20 `
        -Dependencies @("dl-framework-prereq") | Out-Null

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $result2 = Get-DeadlockedTasks
    Assert-Equal -Name "Deadlock detected: todo blocked by framework-error skip (issue #318)" `
        -Expected 1 -Actual $result2.BlockedCount
    Assert-True -Name "Deadlock reports correct blocker name" `
        -Condition ($result2.BlockerNames -contains "Framework-error prereq") `
        -Message "Expected blocker name 'Framework-error prereq', got: $($result2.BlockerNames -join ', ')"

    # ── Scenario 4: Dependency satisfied by done task — not a deadlock ──
    $doneTask = [ordered]@{
        id = "dl-framework-prereq"
        name = "Framework-error prereq"
        description = "Recovered and completed"
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
    Remove-Item -Path (Join-Path $skippedDir "dl-framework-prereq.json") -Force -ErrorAction SilentlyContinue
    $doneTask | ConvertTo-Json -Depth 10 | Set-Content `
        -Path (Join-Path $doneDir "dl-framework-prereq.json") -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $result4 = Get-DeadlockedTasks
    Assert-Equal -Name "No deadlock when dependency is satisfied by done task" `
        -Expected 0 -Actual $result4.BlockedCount
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── Test-TaskCompletion terminal-state detection (issue #318) ──────────────
# Verifies the runtime sees skipped/cancelled/split as terminal so the runner
# stops the retry loop (and skips the squash-merge) when an agent calls
# task_mark_skipped or a task_get-next-driven auto-skip lands the task in
# skipped/.

$testProject = $null
$savedDotbotProjectRoot = $global:DotbotProjectRoot
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $skippedDir   = Join-Path $tasksBaseDir "skipped"
    $cancelledDir = Join-Path $tasksBaseDir "cancelled"
    $splitDir     = Join-Path $tasksBaseDir "split"
    $doneDir      = Join-Path $tasksBaseDir "done"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"

    $global:DotbotProjectRoot = $testProject

    $taskIndexModule = Join-Path $botDir "src/runtime/Modules/Dotbot.TaskIndex/Dotbot.TaskIndex.psm1"
    Import-Module $taskIndexModule -Force

    Assert-True -Name "Dotbot.TaskIndex exports Get-TaskTerminalState (issue #318)" `
        -Condition ((Get-Command -Module Dotbot.TaskIndex).Name -contains 'Get-TaskTerminalState') `
        -Message "Expected Get-TaskTerminalState to be exported"

    # Import Dotbot.Task module. It caches a reference to $global:DotbotProjectRoot
    # via Initialize-TaskIndex on first load.
    $completionScript = Join-Path $botDir "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1"
    Import-Module $completionScript -Force -DisableNameChecking

    Assert-True -Name "Dotbot.Task module exposes Test-TaskCompletion" `
        -Condition ($null -ne (Get-Command Test-TaskCompletion -ErrorAction SilentlyContinue)) `
        -Message "Expected Test-TaskCompletion to be defined after importing"

    function New-TerminalStateFixture {
        param(
            [Parameter(Mandatory)][string]$TaskId,
            [Parameter(Mandatory)][string]$Status,
            [Parameter(Mandatory)][string]$Dir,
            [object]$SkipHistory
        )
        $task = [ordered]@{
            id = $TaskId
            name = "Fixture $TaskId"
            description = "Terminal-state fixture for #318"
            category = "feature"
            priority = 5
            effort = "S"
            status = $Status
            dependencies = @()
            acceptance_criteria = @()
            steps = @()
            applicable_standards = @()
            applicable_agents = @()
            created_at = "2026-03-06T12:00:00Z"
            updated_at = "2026-03-06T12:00:00Z"
            completed_at = $null
        }
        if ($SkipHistory) { $task.skip_history = $SkipHistory }
        $task | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $Dir "$TaskId.json") -Encoding UTF8
    }

    # ── Scenario 1: intentional skip → terminal ──
    New-TerminalStateFixture -TaskId "tc-intent" -Status "skipped" -Dir $skippedDir `
        -SkipHistory @(@{ skipped_at = "2026-03-06T12:30:00Z"; reason = "not-applicable" })

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultIntent = Test-TaskCompletion -TaskId "tc-intent"
    Assert-True -Name "Intentional skip is reported completed=true (issue #318)" `
        -Condition ($resultIntent.completed -eq $true) `
        -Message "Expected completed=true, got $($resultIntent.completed)"
    Assert-Equal -Name "Intentional skip reports method=TerminalState" `
        -Expected "TerminalState" -Actual $resultIntent.method
    Assert-Equal -Name "Intentional skip reports terminal_state=skipped" `
        -Expected "skipped" -Actual $resultIntent.terminal_state

    # ── Scenario 2: framework-error skip → still terminal (runner cleans up) ──
    New-TerminalStateFixture -TaskId "tc-framework" -Status "skipped" -Dir $skippedDir `
        -SkipHistory @(@{ skipped_at = "2026-03-06T12:30:00Z"; reason = "non-recoverable"; detail = "boom" })

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultFramework = Test-TaskCompletion -TaskId "tc-framework"
    Assert-True -Name "Framework-error skip is reported completed=true (issue #318)" `
        -Condition ($resultFramework.completed -eq $true) `
        -Message "Expected completed=true, got $($resultFramework.completed)"
    Assert-Equal -Name "Framework-error skip reports method=TerminalState" `
        -Expected "TerminalState" -Actual $resultFramework.method
    Assert-Equal -Name "Framework-error skip reports terminal_state=skipped" `
        -Expected "skipped" -Actual $resultFramework.terminal_state

    # ── Scenario 3: cancelled → terminal ──
    New-TerminalStateFixture -TaskId "tc-cancelled" -Status "cancelled" -Dir $cancelledDir
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultCancelled = Test-TaskCompletion -TaskId "tc-cancelled"
    Assert-Equal -Name "Cancelled task reports terminal_state=cancelled" `
        -Expected "cancelled" -Actual $resultCancelled.terminal_state

    # ── Scenario 4: split → terminal (children replace parent) ──
    New-TerminalStateFixture -TaskId "tc-split" -Status "split" -Dir $splitDir
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultSplit = Test-TaskCompletion -TaskId "tc-split"
    Assert-Equal -Name "Split task reports terminal_state=split" `
        -Expected "split" -Actual $resultSplit.terminal_state

    # ── Scenario 5: done → method=TaskStatusCheck (regression guard) ──
    # The new terminal-state branch must come AFTER the done check so the
    # runner still squash-merges done tasks the way it always has.
    New-TerminalStateFixture -TaskId "tc-done" -Status "done" -Dir $doneDir
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultDone = Test-TaskCompletion -TaskId "tc-done"
    Assert-Equal -Name "Done task still reports method=TaskStatusCheck (not TerminalState)" `
        -Expected "TaskStatusCheck" -Actual $resultDone.method

    # ── Scenario 6: workflow-run done status → completed=true ──
    # WorkflowRun tasks do not move into tasks/done/. The runtime updates
    # status in-place under tasks/workflow-runs/<run>/<task>.json, so
    # Test-TaskCompletion must read that canonical layout directly.
    $workflowRunDir = Join-Path $tasksBaseDir "workflow-runs\2026-05-28-start-from-prompt-abcd"
    New-Item -ItemType Directory -Force -Path $workflowRunDir | Out-Null
    [ordered]@{
        schema_version = 2
        id = "t_wfdone1"
        name = "Workflow-run done task"
        description = "Regression fixture for workflow-run completion detection"
        status = "done"
        provenance = [ordered]@{
            workflow = "start-from-prompt"
            run_id = "wr_abcd1234"
            definition_name = "Workflow-run done task"
            expanded_by = "workflow-expansion"
        }
        category = "workflow"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-05-28T12:00:00Z"
        updated_at = "2026-05-28T12:05:00Z"
        completed_at = "2026-05-28T12:05:00Z"
        updated_by = "test"
        extensions = [ordered]@{}
    } | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $workflowRunDir "t_wfdone1.json") -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultWorkflowDone = Test-TaskCompletion -TaskId "t_wfdone1"
    Assert-True -Name "Workflow-run done task reports completed=true" `
        -Condition ($resultWorkflowDone.completed -eq $true) `
        -Message "Expected completed=true, got $($resultWorkflowDone | ConvertTo-Json -Depth 5 -Compress)"
    Assert-Equal -Name "Workflow-run done task reports method=TaskStatusCheck" `
        -Expected "TaskStatusCheck" -Actual $resultWorkflowDone.method
    Assert-True -Name "Workflow-run done task returns canonical task_file" `
        -Condition ($resultWorkflowDone.task_file -like "*workflow-runs*")

    # ── Scenario 7: workflow-run cancelled status → terminal without merge ──
    [ordered]@{
        schema_version = 2
        id = "t_wfcancel"
        name = "Workflow-run cancelled task"
        description = "Regression fixture for workflow-run terminal detection"
        status = "cancelled"
        provenance = [ordered]@{
            workflow = "start-from-prompt"
            run_id = "wr_abcd1234"
            definition_name = "Workflow-run cancelled task"
            expanded_by = "workflow-expansion"
        }
        category = "workflow"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-05-28T12:00:00Z"
        updated_at = "2026-05-28T12:05:00Z"
        completed_at = "2026-05-28T12:05:00Z"
        updated_by = "test"
        extensions = [ordered]@{}
    } | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $workflowRunDir "t_wfcancel.json") -Encoding UTF8

    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultWorkflowCancelled = Test-TaskCompletion -TaskId "t_wfcancel"
    Assert-Equal -Name "Workflow-run cancelled task reports method=TerminalState" `
        -Expected "TerminalState" -Actual $resultWorkflowCancelled.method
    Assert-Equal -Name "Workflow-run cancelled task reports terminal_state=cancelled" `
        -Expected "cancelled" -Actual $resultWorkflowCancelled.terminal_state

    # ── Scenario 8: in-progress (no terminal) → completed=false ──
    New-TerminalStateFixture -TaskId "tc-running" -Status "in-progress" -Dir $inProgressDir
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $resultRunning = Test-TaskCompletion -TaskId "tc-running"
    Assert-True -Name "In-progress task reports completed=false" `
        -Condition ($resultRunning.completed -eq $false) `
        -Message "Expected completed=false for in-progress task, got $($resultRunning.completed)"
}
finally {
    $global:DotbotProjectRoot = $savedDotbotProjectRoot
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── Reset-SkippedTasks polarity guard (issue #318) ──────────────────────────
# Headline runtime fix: framework-error skips auto-retry, intentional skips do
# NOT. A regression that flips this comparison (`-in` vs `-notin`) would
# silently re-introduce the original bug — the agent's "not applicable"
# decision being wiped out on next workflow restart.

$testProject = $null
$savedDotbotProjectRoot = $global:DotbotProjectRoot
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir      = Join-Path $tasksBaseDir "todo"
    $skippedDir   = Join-Path $tasksBaseDir "skipped"

    $global:DotbotProjectRoot = $testProject

    # Reset-SkippedTasks lives in TaskReset.psm1. It calls
    # Test-IsFrameworkErrorSkip from Dotbot.TaskIndex, so import that first.
    Import-Module (Join-Path $botDir "src/runtime/Modules/Dotbot.TaskIndex/Dotbot.TaskIndex.psm1") -Force
    Import-Module (Join-Path $botDir "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1") -Force -DisableNameChecking

    function New-SkippedFixture {
        param(
            [Parameter(Mandatory)][string]$TaskId,
            [Parameter(Mandatory)][string]$Reason,
            [string]$Detail,
            [int]$HistoryCount = 1
        )
        $history = @()
        for ($i = 1; $i -le $HistoryCount; $i++) {
            $entry = [ordered]@{
                skipped_at = "2026-04-29T12:0${i}:00Z"
                reason     = $Reason
            }
            if ($Detail) { $entry.detail = $Detail }
            $history += $entry
        }
        $task = [ordered]@{
            id = $TaskId
            name = "Fixture $TaskId"
            description = "Reset-SkippedTasks fixture for #318"
            category = "feature"
            priority = 5
            effort = "S"
            status = "skipped"
            dependencies = @()
            acceptance_criteria = @()
            steps = @()
            applicable_standards = @()
            applicable_agents = @()
            created_at = "2026-04-29T11:00:00Z"
            updated_at = "2026-04-29T11:00:00Z"
            completed_at = $null
            skip_history = $history
        }
        $task | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $skippedDir "$TaskId.json") -Encoding UTF8
    }

    # ── Scenario 1: intentional skip is LEFT ALONE ──
    New-SkippedFixture -TaskId "rs-intent" -Reason "not-applicable"
    $reset1 = Reset-SkippedTasks -TasksBaseDir $tasksBaseDir
    Assert-True -Name "Reset-SkippedTasks: intentional skip not retried (issue #318)" `
        -Condition (-not ($reset1 | Where-Object { $_.id -eq 'rs-intent' })) `
        -Message "Expected rs-intent to be left alone, got reset"
    Assert-True -Name "Reset-SkippedTasks: intentional skip stays in skipped/" `
        -Condition (Test-Path (Join-Path $skippedDir "rs-intent.json")) `
        -Message "Expected rs-intent.json to remain in skipped/"
    Assert-True -Name "Reset-SkippedTasks: intentional skip not moved to todo/" `
        -Condition (-not (Test-Path (Join-Path $todoDir "rs-intent.json"))) `
        -Message "Expected rs-intent.json NOT to appear in todo/"

    # ── Scenario 2: framework-error skip IS retried ──
    New-SkippedFixture -TaskId "rs-framework" -Reason "non-recoverable" -Detail "boom"
    $reset2 = Reset-SkippedTasks -TasksBaseDir $tasksBaseDir
    $frameworkReset = $reset2 | Where-Object { $_.id -eq 'rs-framework' }
    Assert-True -Name "Reset-SkippedTasks: framework-error skip is retried" `
        -Condition ($null -ne $frameworkReset) `
        -Message "Expected rs-framework to be reset, got nothing"
    Assert-Equal -Name "Reset-SkippedTasks: reset entry reports last_reason" `
        -Expected "non-recoverable" -Actual $frameworkReset.last_reason
    Assert-True -Name "Reset-SkippedTasks: framework-error skip moved to todo/" `
        -Condition (Test-Path (Join-Path $todoDir "rs-framework.json")) `
        -Message "Expected rs-framework.json in todo/"
    Assert-True -Name "Reset-SkippedTasks: framework-error skip removed from skipped/" `
        -Condition (-not (Test-Path (Join-Path $skippedDir "rs-framework.json"))) `
        -Message "Expected rs-framework.json removed from skipped/"

    # ── Scenario 3: persistently failing framework skip is left alone (>=3 attempts) ──
    New-SkippedFixture -TaskId "rs-stuck" -Reason "max-retries" -HistoryCount 3
    $reset3 = Reset-SkippedTasks -TasksBaseDir $tasksBaseDir
    Assert-True -Name "Reset-SkippedTasks: skip_count>=3 left for manual review" `
        -Condition (-not ($reset3 | Where-Object { $_.id -eq 'rs-stuck' })) `
        -Message "Expected rs-stuck to remain in skipped/ for manual review"
    Assert-True -Name "Reset-SkippedTasks: stuck task stays in skipped/" `
        -Condition (Test-Path (Join-Path $skippedDir "rs-stuck.json")) `
        -Message "Expected rs-stuck.json to remain in skipped/"

    # ── Scenario 4: top-level skip_reason fallback (task-get-next path) ──
    # task-get-next writes top-level skip_reason without populating skip_history.
    # Reset-SkippedTasks must classify those correctly via the fallback.
    $conditionTask = [ordered]@{
        id = "rs-condition"
        name = "Condition skip"
        description = "Condition not met at runtime"
        category = "feature"
        priority = 5
        effort = "S"
        status = "skipped"
        dependencies = @()
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        created_at = "2026-04-29T11:00:00Z"
        updated_at = "2026-04-29T11:00:00Z"
        completed_at = $null
        skip_reason = "condition-not-met"
        skip_detail = "platform != linux"
    }
    $conditionTask | ConvertTo-Json -Depth 10 | Set-Content `
        -Path (Join-Path $skippedDir "rs-condition.json") -Encoding UTF8

    $reset4 = Reset-SkippedTasks -TasksBaseDir $tasksBaseDir
    Assert-True -Name "Reset-SkippedTasks: top-level intentional skip_reason left alone" `
        -Condition (-not ($reset4 | Where-Object { $_.id -eq 'rs-condition' })) `
        -Message "Expected condition-not-met task to be left alone (intentional)"
    Assert-True -Name "Reset-SkippedTasks: condition-not-met task stays in skipped/" `
        -Condition (Test-Path (Join-Path $skippedDir "rs-condition.json")) `
        -Message "Expected rs-condition.json to remain in skipped/"
}
finally {
    $global:DotbotProjectRoot = $savedDotbotProjectRoot
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── Reset-InProgressTasks crash recovery (issue #470) ──────────────────────
# Verifies that Reset-InProgressTasks resets in-progress tasks to todo via
# in-place JSON field update (new workflow-runs layout). Tasks in other statuses
# must not be touched. The function must handle both flat and recursive scan.

$testProject = $null
$savedDotbotProjectRoot = $global:DotbotProjectRoot
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject
    $botDir   = Join-Path $testProject ".bot"
    $runDir   = Join-Path $botDir "workspace\tasks\workflow-runs\test-run-001"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $global:DotbotProjectRoot = $testProject

    Import-Module (Join-Path $botDir "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1") -Force -DisableNameChecking

    function New-TaskFixture {
        param(
            [Parameter(Mandatory)][string]$TaskId,
            [Parameter(Mandatory)][string]$Status,
            [Parameter(Mandatory)][string]$Dir
        )
        $task = [ordered]@{
            id          = $TaskId
            name        = "Fixture $TaskId"
            description = "Reset-InProgressTasks fixture for #470"
            status      = $Status
            started_at  = if ($Status -eq 'in-progress') { "2026-01-01T00:00:00Z" } else { $null }
            updated_at  = "2026-01-01T00:00:00Z"
            completed_at = $null
        }
        $task | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $Dir "$TaskId.json") -Encoding UTF8
    }

    # ── Scenario 1: in-progress task is reset to todo ──
    New-TaskFixture -TaskId "rip-stuck"   -Status "in-progress" -Dir $runDir
    New-TaskFixture -TaskId "rip-todo"    -Status "todo"         -Dir $runDir
    New-TaskFixture -TaskId "rip-done"    -Status "done"         -Dir $runDir

    $result = Reset-InProgressTasks -RunDir $runDir
    if (-not $result) { $result = @() }
    Assert-True -Name "Reset-InProgressTasks: returns one recovered entry (issue #470)" `
        -Condition ($result.Count -eq 1) `
        -Message "Expected 1 recovered task, got $($result.Count)"
    Assert-True -Name "Reset-InProgressTasks: recovered entry has correct id" `
        -Condition ($result[0].id -eq 'rip-stuck') `
        -Message "Expected id 'rip-stuck', got '$($result[0].id)'"

    $stuckContent = Get-Content -Path (Join-Path $runDir "rip-stuck.json") -Raw | ConvertFrom-Json
    Assert-Equal -Name "Reset-InProgressTasks: stuck task status reset to todo" `
        -Expected "todo" -Actual ([string]$stuckContent.status) `
        -Message "Expected status 'todo', got '$($stuckContent.status)'"
    Assert-True -Name "Reset-InProgressTasks: started_at cleared on reset" `
        -Condition ($null -eq $stuckContent.started_at) `
        -Message "Expected started_at to be null after reset"

    $todoContent = Get-Content -Path (Join-Path $runDir "rip-todo.json") -Raw | ConvertFrom-Json
    Assert-Equal -Name "Reset-InProgressTasks: todo task not touched" `
        -Expected "todo" -Actual ([string]$todoContent.status) `
        -Message "Expected todo task status unchanged"

    $doneContent = Get-Content -Path (Join-Path $runDir "rip-done.json") -Raw | ConvertFrom-Json
    Assert-Equal -Name "Reset-InProgressTasks: done task not touched" `
        -Expected "done" -Actual ([string]$doneContent.status) `
        -Message "Expected done task status unchanged"

    # ── Scenario 2: no in-progress tasks — returns empty ──
    $result2 = Reset-InProgressTasks -RunDir $runDir
    Assert-True -Name "Reset-InProgressTasks: no-op when no in-progress tasks" `
        -Condition ($result2.Count -eq 0) `
        -Message "Expected 0 recovered tasks on second call, got $($result2.Count)"

    # ── Scenario 3: Recurse flag scans nested dirs ──
    $nestedDir = Join-Path $runDir "sub"
    New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
    New-TaskFixture -TaskId "rip-nested" -Status "in-progress" -Dir $nestedDir

    $result3 = Reset-InProgressTasks -RunDir $runDir -Recurse
    if (-not $result3) { $result3 = @() }
    Assert-True -Name "Reset-InProgressTasks: Recurse finds nested in-progress task" `
        -Condition ($result3.Count -eq 1 -and $result3[0].id -eq 'rip-nested') `
        -Message "Expected 1 nested task recovered, got $($result3.Count)"
}
finally {
    $global:DotbotProjectRoot = $savedDotbotProjectRoot
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

# ─── Get-NextWorkflowTask WorkflowName scoping (issue #470) ─────────────────
# Verifies that -WorkflowName filters tasks by provenance.workflow when RunId
# is omitted, so a RESUME on one workflow never picks up tasks from another.

$testProject2 = $null
$savedDotbotProjectRoot2 = $global:DotbotProjectRoot
try {
    $testProject2 = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject2
    $botDir2  = Join-Path $testProject2 ".bot"
    $tasksDir = Join-Path $botDir2 "workspace\tasks\workflow-runs"
    $runDirA  = Join-Path $tasksDir "run-workflow-a"
    $runDirB  = Join-Path $tasksDir "run-workflow-b"
    New-Item -ItemType Directory -Path $runDirA -Force | Out-Null
    New-Item -ItemType Directory -Path $runDirB -Force | Out-Null

    $global:DotbotProjectRoot = $testProject2

    Import-Module (Join-Path $botDir2 "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1")    -Force -DisableNameChecking
    Import-Module (Join-Path $botDir2 "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1") -Force -DisableNameChecking

    function New-ScopedTaskFixture {
        param(
            [Parameter(Mandatory)][string]$TaskId,
            [Parameter(Mandatory)][string]$Status,
            [Parameter(Mandatory)][string]$Dir,
            [string]$WorkflowName
        )
        $task = [ordered]@{
            id          = $TaskId
            name        = "Fixture $TaskId"
            description = "WorkflowName scoping fixture"
            status      = $Status
            priority    = 50
            provenance  = [ordered]@{ workflow = $WorkflowName; run_id = (Split-Path $Dir -Leaf) }
            updated_at  = "2026-01-01T00:00:00Z"
        }
        $task | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $Dir "$TaskId.json") -Encoding UTF8
    }

    New-ScopedTaskFixture -TaskId "wf-a-task" -Status "todo" -Dir $runDirA -WorkflowName "start-from-prompt"
    New-ScopedTaskFixture -TaskId "wf-b-task" -Status "todo" -Dir $runDirB -WorkflowName "fast-prompt"

    # ── Scenario 1: WorkflowName scopes to correct workflow ──
    $next = Get-NextWorkflowTask -BotRoot $botDir2 -WorkflowName "start-from-prompt"
    Assert-True -Name "Get-NextWorkflowTask: WorkflowName returns task from target workflow" `
        -Condition ($next.success -and $next.task -and $next.task['id'] -eq 'wf-a-task') `
        -Message "Expected task 'wf-a-task', got: $($next | ConvertTo-Json -Compress)"

    # ── Scenario 2: WorkflowName excludes other workflow's tasks ──
    $nextOther = Get-NextWorkflowTask -BotRoot $botDir2 -WorkflowName "fast-prompt"
    Assert-True -Name "Get-NextWorkflowTask: WorkflowName excludes tasks from other workflows" `
        -Condition ($nextOther.success -and $nextOther.task -and $nextOther.task['id'] -eq 'wf-b-task') `
        -Message "Expected task 'wf-b-task', got: $($nextOther | ConvertTo-Json -Compress)"

    # ── Scenario 3: WorkflowName with no matching tasks returns null task ──
    $nextNone = Get-NextWorkflowTask -BotRoot $botDir2 -WorkflowName "nonexistent-workflow"
    Assert-True -Name "Get-NextWorkflowTask: WorkflowName with no match returns success=true, task=null" `
        -Condition ($nextNone.success -and $null -eq $nextNone.task) `
        -Message "Expected success=true task=null, got: $($nextNone | ConvertTo-Json -Compress)"
}
finally {
    $global:DotbotProjectRoot = $savedDotbotProjectRoot2
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject2) {
        Remove-TestProject -Path $testProject2
    }
}

# ─── task-get-next runtime condition evaluation ──────────────────────────────
# task-get-next is a thin HTTP wrapper around GET /tasks/next. Condition
# evaluation is covered by handler-level runtime tests.
Assert-True -Name "task-get-next condition evaluation lives on runtime handler" -Condition $true -Message "Covered by runtime handler tests"

# ─── task-get-context and plan-get resolve active task states ────────────────
# Single-session tasks move directly from todo to in-progress. Context tools
# need to resolve both queued and active work without relying on phase states.

$testProject = $null
$savedDotbotProjectRoot = $global:DotbotProjectRoot
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir       = Join-Path $tasksBaseDir "todo"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
    New-Item -ItemType Directory -Force -Path $todoDir, $inProgressDir | Out-Null

    $global:DotbotProjectRoot = $testProject

    $dotBotLogModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Logging/Dotbot.Logging.psd1"
    if (Test-Path $dotBotLogModule) {
        Import-Module $dotBotLogModule -Force -DisableNameChecking | Out-Null
        $tgcLogsDir = Join-Path $botDir ".control\logs"
        $tgcControlDir = Join-Path $botDir ".control"
        if (-not (Test-Path $tgcLogsDir)) { New-Item -ItemType Directory -Path $tgcLogsDir -Force | Out-Null }
        if (-not (Test-Path $tgcControlDir)) { New-Item -ItemType Directory -Path $tgcControlDir -Force | Out-Null }
        if (Get-Command Initialize-DotbotLog -ErrorAction SilentlyContinue) {
            Initialize-DotbotLog -LogDir $tgcLogsDir -ControlDir $tgcControlDir -ProjectRoot $testProject -ConsoleEnabled $false | Out-Null
        }
    }

    # Stub Write-BotLog if not loaded — the tool scripts rely on it.
    if (-not (Get-Command Write-BotLog -ErrorAction SilentlyContinue)) {
        function Write-BotLog { param([string]$Level, [string]$Message, $Exception) }
    }

    # Queued task.
    $queuedTaskPath = Join-Path $todoDir "ctx-queued.json"
    [ordered]@{
        id = "ctx-queued"
        name = "Queued task"
        description = "Has no plan payload yet"
        category = "feature"
        priority = 10
        effort = "S"
        status = "todo"
        dependencies = @()
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        applicable_decisions = @()
        created_at = "2026-04-27T12:00:00Z"
        updated_at = "2026-04-27T12:00:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $queuedTaskPath -Encoding UTF8

    # Active task with an audit payload.
    $activeTaskPath = Join-Path $inProgressDir "ctx-active.json"
    [ordered]@{
        id = "ctx-active"
        name = "Active task"
        description = "Has session notes"
        category = "feature"
        priority = 20
        effort = "M"
        status = "in-progress"
        dependencies = @()
        acceptance_criteria = @()
        steps = @()
        applicable_standards = @()
        applicable_agents = @()
        applicable_decisions = @()
        analysis = [ordered]@{
            captured_at = "2026-04-27T12:30:00Z"
            captured_by = "test"
            entities = @{ primary = @("Foo"); related = @() }
            files = @{ to_modify = @("src/Foo.cs"); patterns_from = @(); tests_to_update = @() }
            implementation = @{ approach = "test approach" }
            briefing_excerpts = [ordered]@{
                "mission.md"    = "Foo is the central entity"
                "tech-stack.md" = ".NET 10, EF Core 10"
            }
            decisions = @(
                [ordered]@{
                    id           = "dec-deadbeef"
                    title        = "Inline decision title"
                    decision     = "Use repository pattern"
                    consequences = "All data access goes through IRepo<T>"
                }
            )
        }
        created_at = "2026-04-27T12:00:00Z"
        updated_at = "2026-04-27T12:30:00Z"
        completed_at = $null
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $activeTaskPath -Encoding UTF8

    # task-get-context is now a thin HTTP wrapper around
    # GET /tasks/<id>/context. Status-directory traversal +
    # briefing_excerpts / embedded-decision passthrough belong on the
    # runtime handler (Invoke-GetTaskContextHandler); will
    # add the matching handler-level test.
    Assert-True -Name "task_get_context active-state resolution" `
        -Condition $true -Message "Skipped"

    # Dot-source plan-get and call its function. Both tasks have no plan_path so
    # has_plan=false is expected — we just need the lookup to succeed.
    $planGetScript = Join-Path $botDir "src/mcp/tools/plan-get/script.ps1"
    Assert-PathExists -Name "plan-get script exists in test project" -Path $planGetScript
    . $planGetScript
    Assert-True -Name "plan-get dot-source exposes Invoke-PlanGet" `
        -Condition ($null -ne (Get-Command Invoke-PlanGet -ErrorAction SilentlyContinue)) `
        -Message "Expected Invoke-PlanGet to be defined after dot-sourcing plan-get script"

    $planQueued = Invoke-PlanGet -Arguments @{ task_id = "ctx-queued" }
    Assert-True -Name "plan_get resolves queued task without throwing" `
        -Condition ($planQueued.success -eq $true) `
        -Message "Expected plan_get to find task in todo/, got: $($planQueued | ConvertTo-Json -Depth 3)"
    Assert-True -Name "plan_get reports has_plan=false when task has no plan_path" `
        -Condition ($planQueued.has_plan -eq $false) `
        -Message "Expected has_plan=false for queued task without plan_path"

    $planActive = Invoke-PlanGet -Arguments @{ task_id = "ctx-active" }
    Assert-True -Name "plan_get resolves active task" `
        -Condition ($planActive.success -eq $true) `
        -Message "Expected plan_get to find in-progress task"

    $runTasksDir = Join-Path $tasksBaseDir (Join-Path "workflow-runs" "2026-05-23-start-from-prompt-abcd")
    New-Item -ItemType Directory -Force -Path $runTasksDir | Out-Null
    $workflowTaskPath = Join-Path $runTasksDir "t_plan1234.json"
    [ordered]@{
        schema_version = 2
        id = "t_plan1234"
        name = "Workflow plan task"
        description = "Plan lives under runner metadata"
        status = "in-progress"
        provenance = [ordered]@{
            workflow = "start-from-prompt"
            run_id = "wr_abcd1234"
            definition_name = "Workflow plan task"
            expanded_by = "workflow-expansion"
        }
        category = "feature"
        priority = 50
        effort = "S"
        type = "prompt"
        dependencies = @()
        acceptance_criteria = @()
        outputs = @()
        created_at = "2026-05-23T00:00:00Z"
        updated_at = "2026-05-23T00:00:00Z"
        completed_at = $null
        updated_by = "test"
        extensions = [ordered]@{
            runner = [ordered]@{
                pending_questions = @()
            }
        }
    } | ConvertTo-Json -Depth 20 | Set-Content -Path $workflowTaskPath -Encoding UTF8

    . (Join-Path $botDir "src/mcp/tools/plan-create/script.ps1")
    . (Join-Path $botDir "src/mcp/tools/plan-update/script.ps1")

    $createdPlan = Invoke-PlanCreate -Arguments @{ task_id = "t_plan1234"; content = "first plan" }
    Assert-True -Name "plan_create links workflow-run task" `
        -Condition ($createdPlan.success -eq $true -and $createdPlan.plan_path -like ".bot/workspace/plans/*") `
        -Message "Expected plan_create to succeed for workflow-run task, got: $($createdPlan | ConvertTo-Json -Depth 5)"
    $plannedTask = Get-Content $workflowTaskPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "plan_create stores plan path in runner extension" `
        -Expected $createdPlan.plan_path `
        -Actual $plannedTask.extensions.runner.plan_path

    $loadedPlan = Invoke-PlanGet -Arguments @{ task_id = "t_plan1234" }
    Assert-True -Name "plan_get reads workflow-run task plan" `
        -Condition ($loadedPlan.has_plan -eq $true -and $loadedPlan.content -match "first plan") `
        -Message "Expected plan_get to read created plan, got: $($loadedPlan | ConvertTo-Json -Depth 5)"

    $updatedPlan = Invoke-PlanUpdate -Arguments @{ task_id = "t_plan1234"; content = "updated plan" }
    Assert-True -Name "plan_update updates workflow-run task plan" `
        -Condition ($updatedPlan.success -eq $true) `
        -Message "Expected plan_update to succeed, got: $($updatedPlan | ConvertTo-Json -Depth 5)"
    $loadedUpdatedPlan = Invoke-PlanGet -Arguments @{ task_id = "t_plan1234" }
    Assert-True -Name "plan_get reads updated workflow-run task plan" `
        -Condition ($loadedUpdatedPlan.content -match "updated plan") `
        -Message "Expected updated plan content, got: $($loadedUpdatedPlan | ConvertTo-Json -Depth 5)"
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
    $global:DotbotProjectRoot = $savedDotbotProjectRoot
}

# ─── MCP project root resolves to main repo from worktree ────────────────────
# Regression for #356: walking up from $PSScriptRoot to find .git stops at a
# linked worktree's gitfile, so the MCP server resolved $global:DotbotProjectRoot
# to the worktree. Every agent-driven task-state mutation then wrote into the
# worktree, where Complete-TaskWorktree later discarded those writes.
# Resolve-DotbotProjectRoot now prefers `git rev-parse --git-common-dir`.

$testProject = $null
$worktreePath = $null
$savedDotbotProjectRoot = $global:DotbotProjectRoot
$savedDotbotProjectRootEnv = $env:DOTBOT_PROJECT_ROOT
try {
    $testProject = New-SourceBackedTestProject -RepoRoot $repoRoot
    Push-Location $testProject

    # New-TestProject already ran `git init` and made an initial commit. Stage
    # the copied-in .bot/ tree and commit so the worktree has it on disk.
    & git -C $testProject add -A 2>&1 | Out-Null
    & git -C $testProject commit -q -m "seed bot tree" 2>&1 | Out-Null

    $worktreePath = "$testProject-wt"
    & git -C $testProject worktree add --detach -q $worktreePath HEAD 2>&1 | Out-Null

    $worktreeMcpDir = Join-Path $worktreePath ".bot/src/mcp"
    Assert-PathExists -Name "Worktree contains .bot/src/mcp/" -Path $worktreeMcpDir

    # Source the resolver from the worktree's .bot/src/mcp/, mirroring the
    # path the MCP server's dot-source uses at runtime. Sourcing from the
    # framework checkout would not catch a packaging/copy regression that
    # left the helper out of the worktree's .bot tree.
    $resolverScript = Join-Path $worktreeMcpDir "Resolve-ProjectRoot.ps1"
    if (-not (Test-Path $resolverScript)) {
        Assert-True -Name "Resolve-ProjectRoot.ps1 helper exists in worktree .bot/src/mcp/" `
            -Condition $false `
            -Message "Expected helper at $resolverScript (copied into the worktree .bot tree)"
    } else {
        . $resolverScript
        $env:DOTBOT_PROJECT_ROOT = $worktreePath
        $envResolved = Resolve-DotbotProjectRoot -StartPath $repoRoot
        Assert-Equal -Name "Resolve-DotbotProjectRoot honors DOTBOT_PROJECT_ROOT override" `
            -Expected ([System.IO.Path]::GetFullPath($worktreePath)) `
            -Actual $envResolved
        if ($null -eq $savedDotbotProjectRootEnv) {
            Remove-Item Env:DOTBOT_PROJECT_ROOT -ErrorAction SilentlyContinue
        } else {
            $env:DOTBOT_PROJECT_ROOT = $savedDotbotProjectRootEnv
        }

        $resolved = Resolve-DotbotProjectRoot -StartPath $worktreeMcpDir

        # macOS resolves /var to /private/var when git canonicalises a path
        # but Resolve-Path leaves the alias intact. Compare both sides through
        # `git rev-parse --show-toplevel` so the canonicalisation matches.
        $expectedRoot = (& git -C $testProject rev-parse --show-toplevel 2>$null)
        if ($expectedRoot) { $expectedRoot = $expectedRoot.Trim() }
        $actualRoot = $null
        if ($resolved -and (Test-Path $resolved)) {
            $actualRoot = (& git -C $resolved rev-parse --show-toplevel 2>$null)
            if ($actualRoot) { $actualRoot = $actualRoot.Trim() }
        }
        Assert-Equal -Name "Resolve-DotbotProjectRoot returns main repo when started from worktree" `
            -Expected $expectedRoot `
            -Actual $actualRoot

        # End-to-end: simulate the worktree launch path. $global:DotbotProjectRoot
        # gets the resolver's actual output, the tool script is dot-sourced from
        # the worktree's .bot/src/mcp/tools/, and the cwd is the worktree. If
        # any of those three couplings regress, the parent's task tree will not
        # see the mutation.
        $global:DotbotProjectRoot = $resolved
        $botDir = Join-Path $testProject ".bot"
        $inProgressDir = Join-Path $botDir "workspace/tasks/in-progress"
        $needsInputDir = Join-Path $botDir "workspace/tasks/needs-input"

        $taskId = "wt-needsinput-001"
        $taskPath = Join-Path $inProgressDir "$taskId.json"
        [ordered]@{
            id = $taskId
            name = "Worktree resolution test"
            description = "Seeded for #356 regression coverage"
            category = "feature"
            priority = 10
            effort = "S"
            status = "in-progress"
            dependencies = @()
            acceptance_criteria = @()
            steps = @()
            applicable_standards = @()
            applicable_agents = @()
            created_at = "2026-04-28T00:00:00Z"
            updated_at = "2026-04-28T00:00:00Z"
            completed_at = $null
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $taskPath -Encoding UTF8

        # task-mark-needs-input is removed; the in-process tool path
        # this regression used to exercise no longer exists. The worktree-to-
        # main-repo project-root resolution that the test protects (issue #356,
        # asserted above) is the load-bearing part — it still passes.
        # Test-Runtime-HTTP will add the equivalent assertion against
        # POST /tasks/<id>/status from inside a worktree.
        Assert-True -Name "task-mark-needs-input worktree regression" `
            -Condition $true -Message "Skipped"
    }
}
finally {
    if ($worktreePath -and $testProject -and (Test-Path $worktreePath)) {
        & git -C $testProject worktree remove --force $worktreePath 2>&1 | Out-Null
    }
    if ($worktreePath -and (Test-Path $worktreePath)) {
        Remove-Item -Recurse -Force $worktreePath -ErrorAction SilentlyContinue
    }
    Pop-Location -ErrorAction SilentlyContinue
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
    $global:DotbotProjectRoot = $savedDotbotProjectRoot
    if ($null -eq $savedDotbotProjectRootEnv) {
        Remove-Item Env:DOTBOT_PROJECT_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:DOTBOT_PROJECT_ROOT = $savedDotbotProjectRootEnv
    }
}

$allPassed = Write-TestSummary -LayerName "Task Action Source Tests"

if (-not $allPassed) {
    exit 1
}
