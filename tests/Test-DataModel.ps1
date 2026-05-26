#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit tests for the canonical data model.
.DESCRIPTION
    Covers the public surface of Dotbot.Task (IdGen, Transitions,
    TaskInstance, Layout) and Dotbot.Workflow (TaskDefinition, WorkflowRun).

    Style: external-behaviour assertions only. No reaching into private helpers.
    Validation tests call the public Test-/Assert-/New- entry points and
    assert on their return value or thrown exception.

    No installed dotbot or AI dependency required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Canonical Data Model" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1") -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

# Small helper: assert a scriptblock throws and the message matches a pattern.
function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$Pattern
    )
    $threw = $false
    $msg = ''
    try {
        & $Action
    } catch {
        $threw = $true
        $msg = $_.Exception.Message
    }
    if (-not $threw) {
        Write-TestResult -Name $Name -Status Fail -Message "Expected an exception, got none."
        return
    }
    if ($Pattern -and ($msg -notmatch $Pattern)) {
        Write-TestResult -Name $Name -Status Fail -Message "Exception '$msg' did not match pattern '$Pattern'."
        return
    }
    Write-TestResult -Name $Name -Status Pass
}

function Assert-DoesNotThrow {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action
    )
    try {
        & $Action
        Write-TestResult -Name $Name -Status Pass
    } catch {
        Write-TestResult -Name $Name -Status Fail -Message "Unexpected exception: $($_.Exception.Message)"
    }
}

# Deep-copy a TaskInstance-shaped hashtable. Returns a hashtable (not ordered)
# but TaskInstance validation doesn't care about key order. JSON roundtrip via
# -AsHashtable preserves both nested objects and nulls.
function Copy-TaskInstance {
    param([Parameter(Mandatory)] $Task)
    return ($Task | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
}

# ═══════════════════════════════════════════════════════════════════
# IdGen
# ═══════════════════════════════════════════════════════════════════

Write-Host "  IdGen — task / workflow-run / short form" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$taskId = New-TaskId
Assert-True -Name "New-TaskId returns a string" -Condition ($taskId -is [string])
Assert-True -Name "New-TaskId matches 't_' + 8 chars [A-Za-z0-9]" -Condition ($taskId -cmatch '^t_[A-Za-z0-9]{8}$')
Assert-True -Name "Test-TaskId accepts a freshly generated id" -Condition (Test-TaskId -Id $taskId)
Assert-True -Name "Test-TaskId rejects empty"        -Condition (-not (Test-TaskId -Id ''))
Assert-True -Name "Test-TaskId rejects null"         -Condition (-not (Test-TaskId -Id $null))
Assert-True -Name "Test-TaskId rejects wrong prefix" -Condition (-not (Test-TaskId -Id 'wr_AbCd1234'))
Assert-True -Name "Test-TaskId rejects short body"   -Condition (-not (Test-TaskId -Id 't_AbCd123'))
Assert-True -Name "Test-TaskId rejects long body"    -Condition (-not (Test-TaskId -Id 't_AbCd12345'))
Assert-True -Name "Test-TaskId rejects '-' (legacy nanoid alphabet)" -Condition (-not (Test-TaskId -Id 't_AbCd-234'))
Assert-True -Name "Test-TaskId rejects uppercase prefix" -Condition (-not (Test-TaskId -Id 'T_AbCd1234'))

$runId = New-WorkflowRunId
Assert-True -Name "New-WorkflowRunId returns string"    -Condition ($runId -is [string])
Assert-True -Name "New-WorkflowRunId matches 'wr_' + 8" -Condition ($runId -cmatch '^wr_[A-Za-z0-9]{8}$')
Assert-True -Name "Test-WorkflowRunId accepts fresh id" -Condition (Test-WorkflowRunId -Id $runId)
Assert-True -Name "Test-WorkflowRunId rejects task id"  -Condition (-not (Test-WorkflowRunId -Id $taskId))

# Get-ShortId behaviour
Assert-Equal -Name "Get-ShortId returns 4-char prefix of task body" `
    -Expected $taskId.Substring(2, 4) `
    -Actual   (Get-ShortId -Id $taskId)

Assert-Equal -Name "Get-ShortId returns 4-char prefix of run body" `
    -Expected $runId.Substring(3, 4) `
    -Actual   (Get-ShortId -Id $runId)

Assert-Throws -Name "Get-ShortId throws on garbage input" `
    -Action { Get-ShortId -Id 'garbage' } `
    -Pattern 'not a canonical'

# Uniqueness sanity — generate 500 ids and verify zero collisions.
$ids = 1..500 | ForEach-Object { New-TaskId }
Assert-Equal -Name "New-TaskId produces unique values across 500 draws" `
    -Expected 500 `
    -Actual   (($ids | Sort-Object -Unique).Count)

# Distribution sanity — every alphabet character should appear at least once
# across 500 ids * 8 chars = 4000 chars (probability of a 0-count under uniform
# is ~62 * (61/62)^4000 ≈ 1e-26 — effectively impossible).
$alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$joined = ($ids | ForEach-Object { $_.Substring(2) }) -join ''
$missing = 0
foreach ($c in $alphabet.ToCharArray()) {
    if ($joined.IndexOf($c) -lt 0) { $missing++ }
}
Assert-Equal -Name "New-TaskId covers full alphabet over 500 draws" -Expected 0 -Actual $missing

# ═══════════════════════════════════════════════════════════════════
# Transitions
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Transitions — closed table enforcement" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$expectedStatuses = @('todo','analysing','analysed','in-progress','needs-review','done','failed','skipped','cancelled','needs-input')
$gotStatuses = Get-TaskStatuses
Assert-Equal -Name "Get-TaskStatuses returns the canonical list (count)" `
    -Expected $expectedStatuses.Count `
    -Actual   $gotStatuses.Count

foreach ($s in $expectedStatuses) {
    Assert-True -Name "Get-TaskStatuses contains '$s'" -Condition ($gotStatuses -contains $s)
}

Assert-True -Name "Test-TaskStatus accepts each canonical status" `
    -Condition (($expectedStatuses | Where-Object { -not (Test-TaskStatus -Status $_) }).Count -eq 0)

Assert-True -Name "Test-TaskStatus rejects 'split' (not a canonical status)" `
    -Condition (-not (Test-TaskStatus -Status 'split'))

Assert-True -Name "Test-TaskStatus rejects empty" -Condition (-not (Test-TaskStatus -Status ''))

# Spot-check each PRD-listed forward edge.
$legalEdges = @(
    @('todo','analysing'), @('todo','skipped'), @('todo','cancelled'),
    @('analysing','analysed'), @('analysing','needs-input'), @('analysing','failed'), @('analysing','cancelled'),
    @('analysed','in-progress'), @('analysed','needs-input'), @('analysed','skipped'), @('analysed','cancelled'),
    @('in-progress','done'), @('in-progress','needs-input'), @('in-progress','failed'), @('in-progress','analysed'), @('in-progress','cancelled'),
    @('needs-input','analysing'), @('needs-input','cancelled'),
    @('done','todo'),
    @('failed','todo'),
    @('skipped','todo')
)
foreach ($edge in $legalEdges) {
    Assert-True -Name "Test-TaskTransition: $($edge[0]) → $($edge[1]) (allowed)" `
        -Condition (Test-TaskTransition -From $edge[0] -To $edge[1])
}

# Illegal edges the PRD explicitly cares about.
$illegalEdges = @(
    @('todo','done'),
    @('todo','in-progress'),
    @('analysing','in-progress'),
    @('cancelled','todo'),         # cancelled is terminal-only
    @('cancelled','analysing'),
    @('cancelled','done'),
    @('done','in-progress'),
    @('failed','done'),
    @('skipped','done'),
    @('needs-input','done')
)
foreach ($edge in $illegalEdges) {
    Assert-True -Name "Test-TaskTransition: $($edge[0]) → $($edge[1]) (denied)" `
        -Condition (-not (Test-TaskTransition -From $edge[0] -To $edge[1]))
}

Assert-True -Name "Test-TaskTransition: self-transition todo → todo denied" `
    -Condition (-not (Test-TaskTransition -From 'todo' -To 'todo'))

# Get-AllowedTransitions content
$fromTodo = Get-AllowedTransitions -From 'todo'
Assert-Equal -Name "Get-AllowedTransitions: todo has 3 exits" -Expected 3 -Actual $fromTodo.Count
Assert-True -Name "Get-AllowedTransitions: todo includes analysing" -Condition ($fromTodo -contains 'analysing')
Assert-True -Name "Get-AllowedTransitions: todo includes skipped"   -Condition ($fromTodo -contains 'skipped')
Assert-True -Name "Get-AllowedTransitions: todo includes cancelled" -Condition ($fromTodo -contains 'cancelled')

$fromCancelled = Get-AllowedTransitions -From 'cancelled'
Assert-Equal -Name "Get-AllowedTransitions: cancelled has 0 exits (terminal)" `
    -Expected 0 -Actual $fromCancelled.Count

# Assert-TaskTransition — throws on illegal, returns silently on legal
Assert-DoesNotThrow -Name "Assert-TaskTransition: todo → analysing returns silently" `
    -Action { Assert-TaskTransition -From 'todo' -To 'analysing' }

Assert-Throws -Name "Assert-TaskTransition: todo → done throws" `
    -Action { Assert-TaskTransition -From 'todo' -To 'done' } `
    -Pattern 'not a legal transition'

Assert-Throws -Name "Assert-TaskTransition: cancelled → todo throws (terminal)" `
    -Action { Assert-TaskTransition -From 'cancelled' -To 'todo' } `
    -Pattern 'cannot leave terminal'

Assert-Throws -Name "Assert-TaskTransition: unknown status throws" `
    -Action { Assert-TaskTransition -From 'todo' -To 'gobbledygook' } `
    -Pattern 'not a valid task status'

# ═══════════════════════════════════════════════════════════════════
# TaskInstance schema
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  TaskInstance — closed shape + validation" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-Equal -Name "Get-TaskInstanceSchemaVersion returns 2" -Expected 2 -Actual (Get-TaskInstanceSchemaVersion)

$fields = Get-TaskInstanceFields
foreach ($required in 'schema_version','id','name','description','status','provenance','extensions','updated_by') {
    Assert-True -Name "Get-TaskInstanceFields includes '$required'" -Condition ($fields -contains $required)
}

# New-TaskInstance builder returns a valid record
$task = New-TaskInstance -Name "Demo task" -Description "Something"
Assert-True -Name "New-TaskInstance result has schema_version=2" -Condition ($task.schema_version -eq 2)
Assert-True -Name "New-TaskInstance result has canonical id"     -Condition (Test-TaskId -Id $task.id)
Assert-True -Name "New-TaskInstance defaults status=todo"        -Condition ($task.status -eq 'todo')
Assert-True -Name "New-TaskInstance default provenance is fully null" `
    -Condition ($null -eq $task.provenance.workflow -and $null -eq $task.provenance.run_id -and $null -eq $task.provenance.definition_name -and $null -eq $task.provenance.expanded_by)
Assert-True -Name "New-TaskInstance result passes Test-TaskInstance with 0 errors" `
    -Condition ((Test-TaskInstance -Task $task).Count -eq 0)

# Workflow-spawned provenance roundtrip
$wfTask = New-TaskInstance -Name "Spawned" -Provenance @{
    workflow        = 'start-from-prompt'
    run_id          = (New-WorkflowRunId)
    definition_name = 'Form UI'
    expanded_by     = 'workflow-expansion'
}
Assert-True -Name "Workflow-spawned task validates" -Condition ((Test-TaskInstance -Task $wfTask).Count -eq 0)
Assert-Equal -Name "Workflow-spawned task records definition_name" `
    -Expected 'Form UI' -Actual $wfTask.provenance.definition_name

# Mid-run task-spawned provenance (expanded_by: 'task:t_<id>')
$childTask = New-TaskInstance -Name "Child" -Provenance @{
    workflow        = 'wf'
    run_id          = (New-WorkflowRunId)
    definition_name = 'Sub-task'
    expanded_by     = "task:$(New-TaskId)"
}
Assert-True -Name "Child task with expanded_by='task:t_<id>' validates" `
    -Condition ((Test-TaskInstance -Task $childTask).Count -eq 0)

# Unknown field rejection (User Story 3)
$withUnknown = @{
    schema_version=2; id=(New-TaskId); name='x'; description=''; status='todo'
    provenance=@{workflow=$null; run_id=$null; definition_name=$null; expanded_by=$null}
    created_at='2026-05-19T00:00:00Z'; updated_at='2026-05-19T00:00:00Z'; completed_at=$null
    updated_by='system'; extensions=@{}
    not_a_real_field='nope'
}
$errs = Test-TaskInstance -Task $withUnknown
Assert-True -Name "Unknown top-level field is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'not_a_real_field' }).Count -gt 0)

# Missing required fields
$missing = @{ name = 'X' }
$errs = Test-TaskInstance -Task $missing
Assert-True -Name "Missing-required-fields produces multiple errors" -Condition ($errs.Count -gt 1)
Assert-True -Name "Missing schema_version is reported" `
    -Condition (($errs | Where-Object { $_ -match '^schema_version' }).Count -gt 0)
Assert-True -Name "Missing id is reported" `
    -Condition (($errs | Where-Object { $_ -match '^id' }).Count -gt 0)

# Invalid schema_version
$wrongSv = Copy-TaskInstance -Task $task; $wrongSv.schema_version = 1
$errs = Test-TaskInstance -Task $wrongSv
Assert-True -Name "Wrong schema_version is rejected" `
    -Condition (($errs | Where-Object { $_ -match '^schema_version' }).Count -gt 0)

# Status enum
$wrongStatus = Copy-TaskInstance -Task $task; $wrongStatus.status = 'split'
$errs = Test-TaskInstance -Task $wrongStatus
Assert-True -Name "Dropped status 'split' is rejected" `
    -Condition (($errs | Where-Object { $_ -match '^status' }).Count -gt 0)

# Terminal-status invariants
$terminalNoCompleted = Copy-TaskInstance -Task $task; $terminalNoCompleted.status = 'done'; $terminalNoCompleted.completed_at = $null
$errs = Test-TaskInstance -Task $terminalNoCompleted
Assert-True -Name "Terminal status with null completed_at is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'completed_at' -and $_ -match 'terminal' }).Count -gt 0)

$nonTerminalWithCompleted = Copy-TaskInstance -Task $task; $nonTerminalWithCompleted.status = 'todo'; $nonTerminalWithCompleted.completed_at = '2026-05-19T00:00:00Z'
$errs = Test-TaskInstance -Task $nonTerminalWithCompleted
Assert-True -Name "Non-terminal status with non-null completed_at is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'completed_at' -and $_ -match 'non-terminal' }).Count -gt 0)

# Provenance — partial provenance rejected
$partialProv = Copy-TaskInstance -Task $task
$partialProv.provenance = @{ workflow='x'; run_id=$null; definition_name=$null; expanded_by=$null }
$errs = Test-TaskInstance -Task $partialProv
Assert-True -Name "Partial provenance (one of four set) is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'provenance' -and $_ -match 'fully' }).Count -gt 0)

# Provenance — unknown sub-field rejected
$unknownProvField = Copy-TaskInstance -Task $task
$unknownProvField.provenance = @{ workflow=$null; run_id=$null; definition_name=$null; expanded_by=$null; extra='x' }
$errs = Test-TaskInstance -Task $unknownProvField
Assert-True -Name "Unknown provenance sub-field is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'provenance.extra' }).Count -gt 0)

# Provenance — bogus expanded_by rejected
$bogusExpanded = Copy-TaskInstance -Task $task
$bogusExpanded.provenance = @{ workflow='x'; run_id=(New-WorkflowRunId); definition_name='d'; expanded_by='spontaneous' }
$errs = Test-TaskInstance -Task $bogusExpanded
Assert-True -Name "Unknown expanded_by value is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'expanded_by' }).Count -gt 0)

# Provenance — bogus run_id rejected
$bogusRunId = Copy-TaskInstance -Task $task
$bogusRunId.provenance = @{ workflow='x'; run_id='wr_short'; definition_name='d'; expanded_by='workflow-expansion' }
$errs = Test-TaskInstance -Task $bogusRunId
Assert-True -Name "Malformed run_id in provenance is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'run_id' }).Count -gt 0)

# Extensions namespace
$task2 = New-TaskInstance -Name "Demo 2" -Extensions @{ 'workflow.start-from-prompt' = @{ phase = 1 }; 'ui' = @{ pinned = $true } }
Assert-True -Name "Extensions with dotted namespace validates" `
    -Condition ((Test-TaskInstance -Task $task2).Count -eq 0)
Assert-Equal -Name "Extensions value round-trips" -Expected 1 -Actual $task2.extensions['workflow.start-from-prompt'].phase

# Extensions with bad key
$badExt = Copy-TaskInstance -Task $task; $badExt.extensions = @{ 'has spaces' = $true }
$errs = Test-TaskInstance -Task $badExt
Assert-True -Name "Extensions key with whitespace is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'extensions' }).Count -gt 0)

# Dependencies — only canonical IDs
$task3 = New-TaskInstance -Name "Demo 3" -Dependencies @((New-TaskId))
Assert-True -Name "Dependencies with valid task IDs validates" `
    -Condition ((Test-TaskInstance -Task $task3).Count -eq 0)

$badDep = Copy-TaskInstance -Task $task; $badDep.dependencies = @('not-an-id')
$errs = Test-TaskInstance -Task $badDep
Assert-True -Name "Dependencies with non-canonical ID is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'dependencies' }).Count -gt 0)

# Bad timestamp format
$badTs = Copy-TaskInstance -Task $task; $badTs.created_at = '2026-05-19 12:34:56'
$errs = Test-TaskInstance -Task $badTs
Assert-True -Name "Non-RFC3339-Z timestamp is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'created_at' }).Count -gt 0)

# Assert-TaskInstance throws on bad
Assert-Throws -Name "Assert-TaskInstance throws on invalid record" `
    -Action { Assert-TaskInstance -Task @{ name = 'X' } } `
    -Pattern 'Invalid TaskInstance'

# JSON roundtrip via -AsHashtable (the codebase's chosen reader)
$json = $task | ConvertTo-Json -Depth 10
$reparsed = $json | ConvertFrom-Json -AsHashtable
$errs = Test-TaskInstance -Task $reparsed
Assert-Equal -Name "JSON roundtrip (-AsHashtable) preserves validity (0 errors)" `
    -Expected 0 -Actual $errs.Count

# ═══════════════════════════════════════════════════════════════════
# Layout
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Layout — on-disk path derivation" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Slug rules
Assert-Equal -Name "ConvertTo-DotbotSlug: spaces→hyphens, lowercase" `
    -Expected 'start-from-prompt' `
    -Actual   (ConvertTo-DotbotSlug -Text 'Start From Prompt')

Assert-Equal -Name "ConvertTo-DotbotSlug: empty→'untitled'" `
    -Expected 'untitled' `
    -Actual   (ConvertTo-DotbotSlug -Text '')

Assert-Equal -Name "ConvertTo-DotbotSlug: punctuation stripped" `
    -Expected 'hello-world' `
    -Actual   (ConvertTo-DotbotSlug -Text 'Hello, World!')

# 40-char cap
$longSlug = ConvertTo-DotbotSlug -Text ('x' * 200)
Assert-True -Name "ConvertTo-DotbotSlug caps at 40 chars" -Condition ($longSlug.Length -le 40)

# Workflow run layout
$wrid = 'wr_AbCd1234'
$layout = Get-WorkflowRunLayout `
    -BotRoot '/proj/.bot' `
    -WorkflowName 'Start From Prompt' `
    -RunId $wrid `
    -StartedAt '2026-05-19T10:00:00Z'

Assert-True -Name "Layout: run_dir ends with date-slug-shortid" `
    -Condition ($layout.run_dir -match '2026-05-19-start-from-prompt-AbCd$')

Assert-True -Name "Layout: run_dir under workspace/tasks/workflow-runs/" `
    -Condition ($layout.run_dir -match '(workspace[/\\]tasks[/\\]workflow-runs)')

Assert-True -Name "Layout: run_record_path is <run_dir>/run.json" `
    -Condition ($layout.run_record_path -match 'run\.json$')

Assert-True -Name "Layout: live_status_path is .control/workflow-runs/<wr_id>.json" `
    -Condition ($layout.live_status_path -match "\.control[/\\]workflow-runs[/\\]$wrid\.json$")

Assert-Equal -Name "Layout: short_id is 4-char prefix of run body" `
    -Expected 'AbCd' -Actual $layout.short_id

Assert-Equal -Name "Layout: tasks_dir equals run_dir" `
    -Expected $layout.run_dir -Actual $layout.tasks_dir

# Task file inside a run dir
$tid = 't_EfGh5678'
$taskPath = Get-RunTaskFilePath -RunDir $layout.run_dir -TaskId $tid
Assert-True -Name "Layout: task file uses canonical id in basename" `
    -Condition ($taskPath -match "[/\\]$tid\.json$")

Assert-Throws -Name "Get-RunTaskFilePath rejects non-canonical task id" `
    -Action { Get-RunTaskFilePath -RunDir $layout.run_dir -TaskId 'whatever' } `
    -Pattern 'not a canonical task ID'

# Standalone task layout
$slayout = Get-StandaloneTaskLayout `
    -BotRoot '/proj/.bot' `
    -TaskId $tid `
    -TaskName 'Fix typo in README' `
    -CreatedAt '2026-05-19T10:00:00Z'

Assert-True -Name "Standalone: file_path under workspace/tasks/standalone/" `
    -Condition ($slayout.file_path -match '(workspace[/\\]tasks[/\\]standalone)')

Assert-True -Name "Standalone: filename ends with .json" `
    -Condition ($slayout.file_path -match '\.json$')

Assert-True -Name "Standalone: filename includes date, slug, 4-char id" `
    -Condition ($slayout.file_name -match '^2026-05-19-fix-typo-in-readme-EfGh\.json$')

# Get-TaskLayoutPath dispatcher
$dispatched1 = Get-TaskLayoutPath `
    -BotRoot '/proj/.bot' `
    -TaskId $tid `
    -RunId $wrid `
    -WorkflowName 'start-from-prompt' `
    -StartedAt '2026-05-19T10:00:00Z'
Assert-True -Name "Dispatcher: with RunId → file under run_dir" `
    -Condition ($dispatched1.file_path -match "$tid\.json$")

$dispatched2 = Get-TaskLayoutPath `
    -BotRoot '/proj/.bot' `
    -TaskId $tid `
    -TaskName 'Standalone thing' `
    -CreatedAt '2026-05-19T10:00:00Z'
Assert-True -Name "Dispatcher: no RunId → standalone path" `
    -Condition ($dispatched2.file_path -match 'standalone[/\\]')

# Layout helpers don't touch the filesystem.
Assert-True -Name "Get-WorkflowRunLayout does NOT create directories" `
    -Condition (-not (Test-Path -LiteralPath '/proj/.bot'))

# ═══════════════════════════════════════════════════════════════════
# TaskDefinition (workflow.yaml entry)
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  TaskDefinition — schema validation" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$validDef = @{
    name        = 'Form UI'
    type        = 'prompt'
    depends_on  = @('Form Logic')
    prompt      = 'Build a login form'
    outputs     = @('src/Form.tsx')
    priority    = 'normal'
    optional    = $false
}
Assert-Equal -Name "TaskDefinition: valid minimal entry → 0 errors" `
    -Expected 0 -Actual (Test-TaskDefinition -TaskDef $validDef).Count

# Missing required
$noName = @{ type = 'prompt' }
$errs = Test-TaskDefinition -TaskDef $noName
Assert-True -Name "TaskDefinition: missing 'name' is rejected" `
    -Condition (($errs | Where-Object { $_ -match '^name' }).Count -gt 0)

$noType = @{ name = 'X' }
$errs = Test-TaskDefinition -TaskDef $noType
Assert-True -Name "TaskDefinition: missing 'type' is rejected" `
    -Condition (($errs | Where-Object { $_ -match '^type' }).Count -gt 0)

# Disallowed legacy fields rejected
foreach ($removed in @('skip_worktree','working_dir','external_repo','commit','front_matter_docs','post_script')) {
    $def = @{ name = 'X'; type = 'prompt'; $removed = 'whatever' }
    $errs = Test-TaskDefinition -TaskDef $def
    Assert-True -Name "TaskDefinition: disallowed field '$removed' is rejected" `
        -Condition (($errs | Where-Object { $_ -match $removed }).Count -gt 0)
}

# Unknown field
$weirdDef = @{ name = 'X'; type = 'prompt'; not_a_field = 'huh' }
$errs = Test-TaskDefinition -TaskDef $weirdDef
Assert-True -Name "TaskDefinition: unknown field is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'not_a_field' }).Count -gt 0)

# depends_on must be array of strings, not a string
$badDeps = @{ name = 'X'; type = 'prompt'; depends_on = 'a-single-string' }
$errs = Test-TaskDefinition -TaskDef $badDeps
Assert-True -Name "TaskDefinition: depends_on as a single string is rejected" `
    -Condition (($errs | Where-Object { $_ -match 'depends_on' }).Count -gt 0)

# Removed-fields list exposed
$removed = Get-TaskDefinitionRemovedFields
foreach ($f in 'skip_worktree','working_dir','external_repo','commit','front_matter_docs','post_script') {
    Assert-True -Name "Get-TaskDefinitionRemovedFields includes '$f'" -Condition ($removed -contains $f)
}

Assert-Throws -Name "Assert-TaskDefinition throws on invalid def" `
    -Action { Assert-TaskDefinition -TaskDef @{ name = 'X' } } `
    -Pattern 'Invalid TaskDefinition'

# ═══════════════════════════════════════════════════════════════════
# WorkflowRun records
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  WorkflowRun — committed + live records" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-Equal -Name "Get-WorkflowRunSchemaVersion returns 1" -Expected 1 -Actual (Get-WorkflowRunSchemaVersion)

# Builder produces a valid record
$tIds = @((New-TaskId), (New-TaskId), (New-TaskId))
$record = New-WorkflowRunRecord -WorkflowName 'start-from-prompt' `
                                -StartedBy 'ui:carlos@host' `
                                -TaskIds $tIds `
                                -Isolated $true `
                                -BranchName 'workflow/sfp-AbCd' `
                                -WorktreePath '/tmp/wt'
Assert-True -Name "WorkflowRun record: builder result validates" `
    -Condition ((Test-WorkflowRunRecord -Record $record).Count -eq 0)
Assert-Equal -Name "WorkflowRun record: schema_version=1" -Expected 1 -Actual $record.schema_version
Assert-True -Name "WorkflowRun record: run_id is canonical wr_" -Condition (Test-WorkflowRunId -Id $record.run_id)
Assert-Equal -Name "WorkflowRun record: task_ids count preserved" -Expected 3 -Actual $record.task_ids.Count

# Builder with a single task — covers the single-element-array unwrap landmine.
$rec1 = New-WorkflowRunRecord -WorkflowName 'wf' -StartedBy 'x' -TaskIds @((New-TaskId))
Assert-Equal -Name "WorkflowRun record: single-task TaskIds preserved as array" `
    -Expected 1 -Actual $rec1.task_ids.Count

# Missing required field
$incomplete = @{ schema_version=1; run_id=(New-WorkflowRunId); workflow_name='wf' }
$errs = Test-WorkflowRunRecord -Record $incomplete
Assert-True -Name "WorkflowRun record: missing required fields reported" -Condition ($errs.Count -gt 1)

# Unknown top-level field
$unknownTop = @{
    schema_version=1; run_id=(New-WorkflowRunId); workflow_name='wf'
    started_at='2026-05-19T00:00:00Z'; isolated=$true; task_ids=@((New-TaskId)); started_by='x'
    extra_thing = 'nope'
}
$errs = Test-WorkflowRunRecord -Record $unknownTop
Assert-True -Name "WorkflowRun record: unknown field reported" `
    -Condition (($errs | Where-Object { $_ -match 'extra_thing' }).Count -gt 0)

# Invalid task ID inside task_ids
$badTaskIds = @{
    schema_version=1; run_id=(New-WorkflowRunId); workflow_name='wf'
    started_at='2026-05-19T00:00:00Z'; isolated=$true; task_ids=@('garbage'); started_by='x'
}
$errs = Test-WorkflowRunRecord -Record $badTaskIds
Assert-True -Name "WorkflowRun record: non-canonical task id in task_ids reported" `
    -Condition (($errs | Where-Object { $_ -match 'task_ids' }).Count -gt 0)

# Status record builder
$rid = $record.run_id
$status = New-WorkflowRunStatus -RunId $rid
Assert-Equal -Name "WorkflowRun status: default status=running" -Expected 'running' -Actual $status.status
Assert-True -Name "WorkflowRun status: valid by default"        -Condition ((Test-WorkflowRunStatus -Status $status).Count -eq 0)

# Bad WorkflowRun status enum value
$bogusStatus = @{ schema_version=1; run_id=$rid; status='whatever' }
$errs = Test-WorkflowRunStatus -Status $bogusStatus
Assert-True -Name "WorkflowRun status: unknown status value reported" `
    -Condition (($errs | Where-Object { $_ -match '^status' }).Count -gt 0)

# Terminal WorkflowRun status requires completed_at
$completedNoStamp = @{ schema_version=1; run_id=$rid; status='completed'; completed_at=$null }
$errs = Test-WorkflowRunStatus -Status $completedNoStamp
Assert-True -Name "WorkflowRun status: terminal status without completed_at reported" `
    -Condition (($errs | Where-Object { $_ -match 'completed_at' }).Count -gt 0)

# JSON roundtrip
$json = $record | ConvertTo-Json -Depth 10
$reparsed = $json | ConvertFrom-Json -AsHashtable
Assert-Equal -Name "WorkflowRun record: JSON roundtrip (-AsHashtable) is valid" `
    -Expected 0 -Actual (Test-WorkflowRunRecord -Record $reparsed).Count

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

$ok = Write-TestSummary -LayerName "Data Model"
exit $(if ($ok) { 0 } else { 1 })
