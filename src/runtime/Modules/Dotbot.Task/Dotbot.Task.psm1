<#
.SYNOPSIS
Task lifecycle: prompt building, completion detection, state recovery,
post-script hooks, merge-failure escalation, interactive interview loop.

.DESCRIPTION
Single module covering everything the task-runner does after picking up a task:

  - Build-TaskPrompt: template substitution from task fields into a prompt.
  - Test-TaskCompletion: detect terminal state from filesystem + Claude output.
  - Reset-InProgressTasks / Reset-SkippedTasks: crash recovery.
  - Invoke-PostScript / Invoke-PostScriptFailureEscalation /
    Invoke-TaskPostScriptIfPresent: post-script hook plumbing.
  - Move-TaskToMergeFailureNeedsInput / Invoke-MergeFailureEscalation:
    HITL escalation for merge failures (rebase conflicts, missing branch,
    failed squash, rejected commit, exception). Kind-aware pending_question.
  - Invoke-InterviewLoop: multi-round Q&A loop for interview-type tasks.

Required manifest dependencies: Dotbot.Core (paths), Dotbot.TaskFile (atomic
task file writes), Dotbot.TaskIndex (task index queries / skip classification),
Dotbot.SessionTracking (session history), Dotbot.Notification (external
notifications).
Ambient dependencies: Dotbot.Process (Write-ProcessActivity / Write-ProcessFile),
Dotbot.Theme (Write-Status), Dotbot.Harness (New-HarnessSession /
Invoke-HarnessStream for the interview loop).
#>

# Initialize task index on first load
$tasksBaseDir = Join-Path (Get-DotbotProjectBotPath) "workspace" "tasks"
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

#region Prompt building

function Build-TaskPrompt {
    <#
    .SYNOPSIS
    Build a complete task prompt from template and task data

    .PARAMETER PromptTemplate
    The template string containing {{VARIABLE}} placeholders

    .PARAMETER Task
    Task object containing task properties

    .PARAMETER SessionId
    Current session ID

    .PARAMETER ProductMission
    Product mission description or file reference

    .PARAMETER EntityModel
    Entity model description or file reference

    .PARAMETER StandardsList
    Formatted list of applicable standards

    .OUTPUTS
    String containing the completed prompt
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptTemplate,

        [Parameter(Mandatory = $true)]
        [object]$Task,

        [Parameter(Mandatory = $true)]
        [string]$SessionId,

        [Parameter(Mandatory = $false)]
        [string]$ProductMission = "No product mission file found.",

        [Parameter(Mandatory = $false)]
        [string]$EntityModel = "No entity model file found.",

        [Parameter(Mandatory = $false)]
        [string]$StandardsList = "No standards files found.",

        [Parameter(Mandatory = $false)]
        [string]$InstanceId = ""
    )

    # Start with template
    $prompt = $PromptTemplate

    # Replace basic task info
    $taskId = if ($Task.id) { "$($Task.id)" } else { "" }
    $taskIdShort = if ($taskId.Length -gt 8) { $taskId.Substring(0, 8) } else { $taskId }

    $instanceIdShort = ""
    if ($InstanceId) {
        $guidMatch = [regex]::Match($InstanceId, '^[0-9a-fA-F]{8}')
        if ($guidMatch.Success) {
            $instanceIdShort = $guidMatch.Value.ToLowerInvariant()
        }
    }

    $prompt = $prompt -replace '\{\{SESSION_ID\}\}', $SessionId
    $prompt = $prompt -replace '\{\{TASK_ID\}\}', $taskId
    $prompt = $prompt -replace '\{\{TASK_ID_SHORT\}\}', $taskIdShort
    $prompt = $prompt -replace '\{\{TASK_NAME\}\}', $Task.name
    $prompt = $prompt -replace '\{\{TASK_CATEGORY\}\}', $Task.category
    $prompt = $prompt -replace '\{\{TASK_PRIORITY\}\}', $Task.priority
    $prompt = $prompt -replace '\{\{TASK_DESCRIPTION\}\}', $Task.description
    $prompt = $prompt -replace '\{\{PRODUCT_MISSION\}\}', $ProductMission
    $prompt = $prompt -replace '\{\{ENTITY_MODEL\}\}', $EntityModel
    $prompt = $prompt -replace '\{\{INSTANCE_ID\}\}', $InstanceId
    $prompt = $prompt -replace '\{\{INSTANCE_ID_SHORT\}\}', $instanceIdShort
    # Format and replace applicable standards
    $applicableStandards = ""
    if ($Task.applicable_standards -and $Task.applicable_standards.Count -gt 0) {
        $applicableStandards = ($Task.applicable_standards | ForEach-Object { "- $_" }) -join "`n"
    } else {
        # Neutral fallback. The previous wording pushed agents toward
        # `.bot/recipes/standards/global/`, which is optional and absent in
        # most workflows; the analysis prompt already tells the agent not to
        # probe that directory.
        $applicableStandards = "No specific standards listed for this task — infer conventions from the codebase."
    }
    $prompt = $prompt -replace '\{\{APPLICABLE_STANDARDS\}\}', $applicableStandards

    # Format and replace applicable agents
    $applicableAgents = ""
    if ($Task.applicable_agents -and $Task.applicable_agents.Count -gt 0) {
        $applicableAgents = ($Task.applicable_agents | ForEach-Object { "- $_" }) -join "`n"
    } else {
        $applicableAgents = "Use .bot/content/agents/implementer/AGENT.md as your default persona"
    }
    $prompt = $prompt -replace '\{\{APPLICABLE_AGENTS\}\}', $applicableAgents

    # Format and replace applicable skills
    $applicableSkills = ""
    if ($Task.applicable_skills -and $Task.applicable_skills.Count -gt 0) {
        $applicableSkills = ($Task.applicable_skills | ForEach-Object { "- $_" }) -join "`n"
    } else {
        $applicableSkills = "No specific skills listed — use judgement based on task category"
    }
    $prompt = $prompt -replace '\{\{APPLICABLE_SKILLS\}\}', $applicableSkills

    # Format and replace acceptance criteria
    $acceptanceCriteria = if ($Task.acceptance_criteria) {
        ($Task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "No specific acceptance criteria defined."
    }
    $prompt = $prompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria

    # Format and replace steps
    $steps = if ($Task.steps) {
        ($Task.steps | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "No specific steps defined."
    }
    $prompt = $prompt -replace '\{\{TASK_STEPS\}\}', $steps

    # Replace standards list
    $prompt = $prompt -replace '\{\{STANDARDS_LIST\}\}', $StandardsList

    # Format and replace questions resolved (user decisions from analysis Q&A)
    $questionsResolved = ""
    if ($Task.questions_resolved -and $Task.questions_resolved.Count -gt 0) {
        $questionsResolved = "The following decisions were made by the user during analysis. You **MUST** honour them — do not contradict or override these answers.`n`n"
        foreach ($qa in $Task.questions_resolved) {
            $questionsResolved += "**Q:** $($qa.question)`n"
            $questionsResolved += "**A:** $($qa.answer)`n`n"
        }
    }
    $prompt = $prompt -replace '\{\{QUESTIONS_RESOLVED\}\}', $questionsResolved

    # Format and replace reviewer feedback accumulated across review cycles
    $reviewerFeedback = ""
    if ($Task.review_feedback -and $Task.review_feedback.Count -gt 0) {
        $reviewerFeedback = "A reviewer rejected your previous attempt. You **MUST** address each item below. The worktree already contains your prior attempt — make targeted corrections per this feedback; do not rewrite sections the feedback does not touch.`n`n"
        foreach ($item in $Task.review_feedback) {
            $reviewerFeedback += "- **What to change:** $($item.comment)`n"
            if ($item.what_was_wrong) {
                $reviewerFeedback += "  **What was wrong:** $($item.what_was_wrong)`n"
            }
        }
        $reviewerFeedback += "`n"
    }
    $prompt = $prompt -replace '\{\{REVIEWER_FEEDBACK\}\}', $reviewerFeedback

    $resumeContext = ""
    if ($Task.resume_context) {
        try {
            $resumeContext = $Task.resume_context | ConvertTo-Json -Depth 20
        } catch {
            $resumeContext = [string]$Task.resume_context
        }
    }
    $prompt = $prompt -replace '\{\{RESUME_CONTEXT\}\}', $resumeContext

    # Add steering protocol include
    $steeringProtocolPath = Join-Path $PSScriptRoot ".." ".." ".." "prompts" "92-steering-protocol.include.md"
    $steeringProtocol = ""
    if (Test-Path $steeringProtocolPath) {
        $steeringProtocol = Get-Content $steeringProtocolPath -Raw -ErrorAction SilentlyContinue
    }
    $prompt = $prompt -replace '\{\{STEERING_PROTOCOL\}\}', $steeringProtocol

    return $prompt
}

function Resolve-TaskReviewDecision {
    <#
    .SYNOPSIS
    Compute the state mutation for a non-approve review decision (reject or revise).

    .DESCRIPTION
    Pure decision logic shared by the MCP submit-review tool and the UI's
    Submit-TaskReview. It does NOT perform any I/O: callers apply the returned
    descriptor with their own runtime client and conditionally call
    Reset-TaskWorktree. This keeps the feedback-assembly and decision->state
    mapping in one place while leaving each caller's request/error semantics
    intact.

    Both 'reject' and 'revise' append the reviewer comment to
    extensions.review.feedback[] and return the task to todo, so the feedback is
    injected into the next execution prompt. They differ only in whether the
    worktree is discarded: reject resets it (fresh regeneration), revise
    preserves it (targeted in-place correction).

    .PARAMETER Task
    The task object as returned by GET /tasks/<id> (already fetched by the caller).

    .PARAMETER Decision
    'reject' or 'revise'.

    .PARAMETER Now
    UTC timestamp string to stamp on the feedback entry and review status.

    .OUTPUTS
    On a validation failure: @{ success = $false; error = <message> }.
    On success: @{
        success           = $true
        reviewReplacement = <extensions.review shape to PATCH>
        targetStatus      = 'todo'
        statusReason      = <transition reason string>
        resetWorktree     = <bool: $true for reject, $false for revise>
        feedbackCount     = <int>
    }
    #>
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [ValidateSet('reject', 'revise')] [string]$Decision,
        [string]$Comment,
        [string]$WhatWasWrong,
        [Parameter(Mandatory)] [string]$Now
    )

    if ([string]::IsNullOrWhiteSpace($Comment)) {
        return @{ success = $false; error = "'comment' is required when ${Decision}ing — describe what needs to change so the implementor can act on the feedback" }
    }

    $feedbackEntry = [ordered]@{
        comment        = "$Comment"
        what_was_wrong = if ($WhatWasWrong) { "$WhatWasWrong" } else { "" }
        timestamp      = $Now
    }
    $existingFeedback = @()
    if ($Task.extensions -and $Task.extensions.PSObject.Properties['review'] -and
        $Task.extensions.review.PSObject.Properties['feedback'] -and $Task.extensions.review.feedback) {
        $existingFeedback = @($Task.extensions.review.feedback)
    }
    $newFeedback = @($existingFeedback) + @($feedbackEntry)

    $isReject = $Decision -eq 'reject'
    $reviewReplacement = @{
        required       = $true
        status         = if ($isReject) { 'rejected' } else { 'revision_requested' }
        feedback       = $newFeedback
        pending_commit = $null
        requested_at   = $null
        request_reason = $null
    }
    if ($isReject) {
        $reviewReplacement.rejected_at = $Now
    } else {
        $reviewReplacement.revision_requested_at = $Now
    }

    return @{
        success           = $true
        reviewReplacement = $reviewReplacement
        targetStatus      = 'todo'
        statusReason      = "Review ${Decision}ed: $Comment"
        resetWorktree     = $isReject
        feedbackCount     = $newFeedback.Count
    }
}

#endregion

#region Completion detection

function Get-CanonicalTaskCompletionRecord {
    <#
    .SYNOPSIS
    Read a task from the canonical task-file layouts when it is not present
    in the legacy state-directory index.

    .DESCRIPTION
    WorkflowRun tasks stay in workspace/tasks/workflow-runs/<run>/<id>.json and
    standalone tasks stay in workspace/tasks/standalone/*.json. Their lifecycle
    is represented by the JSON status field, not by moving files between
    workspace/tasks/done, skipped, etc. Completion detection must understand
    both layouts or a successful task_set_status(done) is misread as failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )

    $tasksRoot = $tasksBaseDir
    if (-not $tasksRoot) { $tasksRoot = Join-Path (Get-DotbotProjectBotPath) "workspace" "tasks" }
    if (-not (Test-Path -LiteralPath $tasksRoot)) { return $null }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    $runsRoot = Join-Path $tasksRoot 'workflow-runs'
    if (Test-Path -LiteralPath $runsRoot) {
        foreach ($hit in @(Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter "$TaskId.json" -File -ErrorAction SilentlyContinue)) {
            $candidatePaths.Add($hit.FullName) | Out-Null
        }
    }

    $standaloneRoot = Join-Path $tasksRoot 'standalone'
    if (Test-Path -LiteralPath $standaloneRoot) {
        foreach ($hit in @(Get-ChildItem -LiteralPath $standaloneRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $candidatePaths.Add($hit.FullName) | Out-Null
        }
    }

    foreach ($path in @($candidatePaths | Select-Object -Unique)) {
        try {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            if ([string]$content.id -ne $TaskId) { continue }
            return [pscustomobject]@{
                status    = [string]$content.status
                task      = [pscustomobject]@{
                    id             = $content.id
                    name           = $content.name
                    description    = $content.description
                    category       = $content.category
                    priority       = $content.priority
                    effort         = $content.effort
                    dependencies   = $content.dependencies
                    completed_at   = $content.completed_at
                    file_path      = $path
                    workflow       = if ($content.provenance -and $content.provenance.workflow) { $content.provenance.workflow } else { $content.workflow }
                }
                file_path = $path
            }
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message "Failed to read canonical task completion record '$path'" -Exception $_
            }
        }
    }

    return $null
}

function Test-TaskCompletion {
    <#
    .SYNOPSIS
    Check if a task has been completed successfully

    .PARAMETER TaskId
    The ID of the task to check

    .PARAMETER ClaudeOutput
    The output from Claude to check for completion markers
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $false)]
        [string]$ClaudeOutput = ""
    )

    # Index always reads fresh from filesystem (no caching)

    # Primary method: look at the task's physical directory (issue #318). We
    # cannot rely on Test-TaskDone here — that helper consults DoneIds, which
    # also includes intentional skips and split parents (dependency satisfiers).
    # The completion check must distinguish "task ended in done/" from "task
    # ended in skipped/cancelled/split"; otherwise the runner squash-merges
    # an intentionally skipped task to main.
    $terminalState = Get-TaskTerminalState -TaskId $TaskId
    if ($terminalState -eq 'done') {
        $task = Get-TaskById -TaskId $TaskId
        return @{
            completed = $true
            method = "TaskStatusCheck"
            reason = "Task found in done directory"
            task_file = $task.file_path
        }
    }
    if ($terminalState) {
        # skipped/cancelled/split — terminal but not done. The runner uses
        # method=TerminalState to clean up the worktree without merging.
        $task = Get-TaskById -TaskId $TaskId
        return @{
            completed     = $true
            method        = "TerminalState"
            reason        = "Task is in terminal state: $terminalState"
            terminal_state = $terminalState
            task_file     = $task.file_path
        }
    }

    $canonicalRecord = Get-CanonicalTaskCompletionRecord -TaskId $TaskId
    if ($canonicalRecord) {
        $canonicalTerminal = switch ($canonicalRecord.status) {
            'done'      { 'done' }
            'failed'    { 'failed' }
            'skipped'   { 'skipped' }
            'cancelled' { 'cancelled' }
            default     { $null }
        }

        if ($canonicalTerminal -eq 'done') {
            return @{
                completed = $true
                method = "TaskStatusCheck"
                reason = "Task status is done in canonical task file"
                task_file = $canonicalRecord.file_path
            }
        }
        if ($canonicalTerminal) {
            return @{
                completed     = $true
                method        = "TerminalState"
                reason        = "Task is in terminal state: $canonicalTerminal"
                terminal_state = $canonicalTerminal
                task_file     = $canonicalRecord.file_path
            }
        }
    }

    # Secondary method: Check for completion marker in Claude output
    # Format: TASK_{TASK_ID}_COMPLETE
    $completionMarker = "TASK_${TaskId}_COMPLETE"
    if ($ClaudeOutput -match [regex]::Escape($completionMarker)) {
        return @{
            completed = $true
            method = "OutputMarker"
            reason = "Completion marker found in Claude output"
            marker = $completionMarker
        }
    }

    # Tertiary method: Check if Claude called task_set_status({ status: 'done' })
    # via MCP. This would be detected by the task being in done directory
    # (covered by the primary method) but we can also pattern-match the
    # tool call in Claude's output.
    #
    # We accept both arg orders (task_id first, status first) and keep the
    # legacy `task_mark_done.*<id>` regex so transcripts from older runs still
    # surface the right diagnostic.
    $markCall = ($ClaudeOutput -match "task_set_status.*$TaskId.*done") -or
                ($ClaudeOutput -match "task_set_status.*done.*$TaskId") -or
                ($ClaudeOutput -match "task_mark_done.*$TaskId")
    if ($markCall -or ($ClaudeOutput -match "marked.*complete.*$TaskId")) {

        # Double-check if task is actually in done directory
        # (cache was already refreshed at start of function)
        if ((Get-TaskTerminalState -TaskId $TaskId) -eq 'done') {
            $task = Get-TaskById -TaskId $TaskId
            return @{
                completed = $true
                method = "MCPCall"
                reason = "MCP task_set_status (status=done) was called and task is in done directory"
                task_file = $task.file_path
            }
        }

        # MCP call detected but task not in done directory
        return @{
            completed = $false
            method = "MCPCallIncomplete"
            reason = "task_set_status (status=done) was called but task is not in done directory (verification may have failed)"
        }
    }

    # Task not completed
    return @{
        completed = $false
        method = "NotCompleted"
        reason = "Task not found in done directory and no completion markers detected"
    }
}

#endregion

#region State recovery (Reset-* helpers)

function Reset-InProgressTasks {
    <#
    .SYNOPSIS
    Reset in-progress tasks to todo status for crash recovery.

    .DESCRIPTION
    Scans $RunDir for task JSON files whose status field is 'in-progress' and
    resets them to 'todo' via an atomic in-place write. Designed for the current
    workflow-runs layout where files never move between directories — status is
    a JSON field. Called at process startup to recover tasks left in-progress by
    a previously killed runner.

    .PARAMETER RunDir
    Directory to scan. For a workflow run: the resolved run dir
    (workspace/tasks/workflow-runs/<runId>). For the pending-task-scope (no RunId):
    the tasks base dir scanned recursively.

    .PARAMETER Recurse
    When set, scans $RunDir recursively. Used for the no-RunId (pending-task-scope)
    case where tasks may be nested under workflow-runs/ and standalone/.

    .PARAMETER ExcludeRunIds
    Run IDs whose in-progress tasks must not be reset. Pass the run_id values of
    all currently active processes so their tasks are left untouched.

    .PARAMETER WorkflowName
    When set, only reset tasks whose provenance.workflow matches this value.
    Use when the runner is scoped to a specific workflow (RESUME by workflow name).

    .OUTPUTS
    Array of hashtables @{ id; name; file } for each recovered task.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunDir,

        [switch]$Recurse,

        [string[]]$ExcludeRunIds = @(),

        [string]$WorkflowName = ''
    )

    $resetTasks = @()

    if (-not (Test-Path -LiteralPath $RunDir)) {
        return ,$resetTasks
    }

    $taskFiles = @(Get-ChildItem -LiteralPath $RunDir -Filter '*.json' -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'run.json' })

    foreach ($taskFile in $taskFiles) {
        try {
            if (-not (Test-Path -LiteralPath $taskFile.FullName)) { continue }

            $taskContent = Get-Content -LiteralPath $taskFile.FullName -Raw | ConvertFrom-Json
            if ([string]$taskContent.status -ne 'in-progress') { continue }

            # Skip tasks whose owning run has a live process.
            if ($ExcludeRunIds.Count -gt 0) {
                $taskRunId = if ($taskContent.PSObject.Properties['provenance'] -and $taskContent.provenance) {
                    [string]$taskContent.provenance.run_id
                } else { $null }
                if ($taskRunId -and $ExcludeRunIds -contains $taskRunId) { continue }
            }

            # Scope to a specific workflow when the runner was started for one.
            if ($WorkflowName) {
                $taskWorkflow = if ($taskContent.PSObject.Properties['provenance'] -and $taskContent.provenance) {
                    [string]$taskContent.provenance.workflow
                } else { $null }
                if ($taskWorkflow -ne $WorkflowName) { continue }
            }

            $taskId   = [string]$taskContent.id
            $taskName = if ($taskContent.PSObject.Properties['name'] -and $taskContent.name) { [string]$taskContent.name } else { $taskId }

            $taskContent.status = 'todo'
            if ($taskContent.PSObject.Properties['started_at'])  { $taskContent.started_at  = $null }
            if ($taskContent.PSObject.Properties['updated_at'])  { $taskContent.updated_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

            Write-TaskFileAtomic -Path $taskFile.FullName -Content $taskContent -Depth 20 -TaskId $taskId

            $resetTasks += @{ id = $taskId; name = $taskName; file = $taskFile.Name }
        } catch {
            Write-BotLog -Level Warn -Message "Reset-InProgressTasks: error processing '$($taskFile.Name)'" -Exception $_
        }
    }

    return ,$resetTasks
}

function Get-NeedsInputTasksInScope {
    <#
    .SYNOPSIS
    Returns task content objects for all tasks in needs-input status within the given scope.

    .PARAMETER RunDir
    Directory to scan (same semantics as Reset-InProgressTasks).

    .PARAMETER Recurse
    When set, scans recursively.

    .OUTPUTS
    Array of PSCustomObject task content. Empty array when none found.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RunDir,

        [switch]$Recurse,

        [string]$WorkflowName = ''
    )

    if (-not (Test-Path -LiteralPath $RunDir)) { return @() }

    @(Get-ChildItem -LiteralPath $RunDir -Filter '*.json' -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'run.json' } |
        ForEach-Object {
            try {
                $c = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                if ([string]$c.status -eq 'needs-input') {
                    $matchesWorkflow = -not $WorkflowName -or (
                        $c.PSObject.Properties['provenance'] -and $c.provenance -and
                        [string]$c.provenance.workflow -eq $WorkflowName
                    )
                    if ($matchesWorkflow) { $c }
                }
            } catch {
                Write-BotLog -Level Debug -Message "Get-NeedsInputTasksInScope: error reading '$($_.Name)'" -Exception $_
            }
        } | Where-Object { $_ })
}

function Reset-SkippedTasks {
    <#
    .SYNOPSIS
    Auto-retry skipped tasks that failed with a framework error (issue #318).

    .DESCRIPTION
    Operates on the skipped/ directory. Tasks whose latest skip is
    INTENTIONAL ('not-applicable', 'precondition-unmet', etc.) are LEFT
    ALONE — those are deliberate decisions and must not be auto-retried.
    Tasks whose latest skip is a framework error ('non-recoverable',
    'max-retries') are moved back to todo/ for another attempt.

    A persistently failing task (skip_history.Count >= 3) is left in
    skipped/ for operator inspection.

    .PARAMETER TasksBaseDir
    Base directory containing task subdirectories (todo, in-progress, skipped, done)

    .OUTPUTS
    Array of hashtables with reset task information
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TasksBaseDir
    )

    $resetTasks = @()
    $skippedDir = Join-Path $TasksBaseDir "skipped"

    if (-not (Test-Path $skippedDir)) {
        return $resetTasks
    }

    $skippedTasks = @(Get-ChildItem -Path $skippedDir -Filter "*.json" -File -ErrorAction SilentlyContinue)

    if ($skippedTasks.Count -eq 0) {
        return $resetTasks
    }

    # Skip-reason classification lives in Dotbot.TaskIndex (single source of
    # truth, issue #318), loaded through this module's manifest.
    if (-not (Get-Command Test-IsFrameworkErrorSkip -ErrorAction SilentlyContinue)) {
        # Without the classifier the per-file try/catch would swallow a
        # CommandNotFoundException and silently leave every skipped task in
        # place. Surface the failure once instead.
        throw "Reset-SkippedTasks requires Test-IsFrameworkErrorSkip from Dotbot.TaskIndex, which could not be loaded."
    }

    foreach ($taskFile in $skippedTasks) {
        try {
            # Re-verify file exists (may have been moved by concurrent process)
            if (-not (Test-Path $taskFile.FullName)) { continue }

            $taskContent = Get-Content -LiteralPath $taskFile.FullName -Raw | ConvertFrom-Json
            $taskId = $taskContent.id
            $taskName = $taskContent.name

            # Issue #318: only framework-error skips are auto-retried.
            # Intentional skips (not-applicable etc.) are deliberate and stay put.
            if (-not (Test-IsFrameworkErrorSkip -TaskContent $taskContent)) {
                continue
            }

            # Resolve the canonical reason once for reporting (latest
            # skip_history entry, fall back to top-level skip_reason).
            $latestReason = $null
            if ($taskContent.skip_history) {
                $entries = @($taskContent.skip_history)
                if ($entries.Count -gt 0 -and $entries[-1].reason) {
                    $latestReason = [string]$entries[-1].reason
                }
            }
            if (-not $latestReason -and $taskContent.skip_reason) {
                $latestReason = [string]$taskContent.skip_reason
            }

            # Guard against infinite skip loops — leave persistently-failing tasks for manual review
            $skipCount = ($taskContent.skip_history | Measure-Object).Count
            if ($skipCount -ge 3) {
                Write-BotLog -Level Warn -Message "Task '$taskName' skipped $skipCount times - leaving in skipped for manual review"
                continue
            }

            # Check if this task was already completed — if so, just delete the orphan
            $doneFile = Join-Path $TasksBaseDir "done" $taskFile.Name
            if (Test-Path $doneFile) {
                Remove-TaskFileAtomic -Path $taskFile.FullName -TaskId $taskId
                continue
            }

            # Move to todo directory
            $todoDir = Join-Path $TasksBaseDir "todo"
            $todoPath = Join-Path $todoDir $taskFile.Name

            # Update status
            $taskContent.status = "todo"
            $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Preserve skip_history as audit trail (intentional)

            # Atomic move: write target first, then delete source.
            Move-TaskFileAtomic -SourcePath $taskFile.FullName `
                                -TargetPath $todoPath `
                                -Content $taskContent `
                                -Depth 10 `
                                -TaskId $taskId

            $resetTasks += @{
                id = $taskId
                name = $taskName
                file = $taskFile.Name
                skip_count = $skipCount
                last_reason = $latestReason
            }
        } catch {
            Write-BotLog -Level Warn -Message "Error processing skipped task: $($taskFile.Name)" -Exception $_
        }
    }

    return $resetTasks
}

#endregion

#region Post-script hooks
# post_script path resolution: "scripts/..." resolves relative to $BotRoot;
# any other path resolves relative to $BotRoot/src/runtime. Slashes are
# normalised so the resolved path is valid on Windows and Unix.

function Invoke-PostScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$ProcessId,
        [Parameter(Mandatory)][string]$RawPostScript
    )

    # NOTE: post_script is trusted manifest input (developer-authored, checked in).
    # Normalise backslashes to forward slashes so Join-Path produces a valid
    # path on both Windows and Unix (Windows accepts either separator).
    $normalized = $RawPostScript -replace '\\', '/'

    $postPath = if ($normalized -match '^scripts/') {
        Join-Path $BotRoot $normalized
    } else {
        Join-Path (Join-Path $BotRoot "src" "runtime") $normalized
    }

    if (-not (Test-Path $postPath)) {
        throw "post_script not found: $postPath"
    }

    Write-Status "Running post-script: $RawPostScript" -Type Process
    Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Executing post_script: $RawPostScript"

    $global:LASTEXITCODE = 0
    & $postPath -BotRoot $BotRoot -ProductDir $ProductDir -Settings $Settings -Model $Model -ProcessId $ProcessId
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "post_script exited with code $LASTEXITCODE"
    }
}

<#
.SYNOPSIS
Escalate a post_script failure by moving a task from done/ → needs-input/.

.DESCRIPTION
Used by the Claude-executed branch in Invoke-WorkflowProcess.ps1 when a
post_script fails after `task_set_status({ status: 'done' })` has already moved the task JSON into
`workspace\tasks\done\`. Rather than destroy the worktree and increment failure
counters, we move the task to `workspace\tasks\needs-input\` with a
`pending_question` so the operator can inspect the worktree, fix the post_script
(or the artefacts it consumes), and retry manually.

Mirrors the merge-conflict escalation pattern already used when the squash-merge
step fails. Returns $true if the task was moved, $false otherwise (e.g. the task
JSON was not found in done/).
#>
function Invoke-PostScriptFailureEscalation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$TasksBaseDir,
        [Parameter(Mandatory)][string]$PostScriptError,
        [AllowEmptyString()][string]$WorktreePath = "",
        # Source of the failure controls the user-facing pending_question text.
        # 'post_script'    — real post_script hook failure (default; back-compat).
        # 'clarification'  — clarification HITL loop failure or operator stop.
        # 'outputs'        — task-declared outputs missing after completion.
        # 'front_matter'   — JSON front-matter injection failure.
        [ValidateSet('post_script', 'clarification', 'outputs', 'front_matter')]
        [string]$FailureSource = 'post_script'
    )

    $doneDir = Join-Path $TasksBaseDir "done"
    $needsInputDir = Join-Path $TasksBaseDir "needs-input"

    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }

    $taskFile = Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
        try {
            $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $c.id -eq $Task.id
        } catch { $false }
    } | Select-Object -First 1

    if (-not $taskFile) { return $false }

    $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
    $nowIso = (Get-Date).ToUniversalTime().ToString("o")

    # Use Add-Member -Force so the helper works on task JSON that may or may not
    # already have status / updated_at / pending_question properties.
    $taskContent | Add-Member -NotePropertyName 'status' -NotePropertyValue 'needs-input' -Force
    $taskContent | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue $nowIso -Force

    if (-not $taskContent.PSObject.Properties['pending_question']) {
        $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
    }

    $contextText = if ($WorktreePath) {
        "Error: $PostScriptError. Worktree preserved at: $WorktreePath"
    } else {
        "Error: $PostScriptError"
    }

    # Pick user-facing strings based on failure source. Default ('post_script')
    # preserves prior behavior for back-compat with existing tests/assertions.
    $sourceMessaging = switch ($FailureSource) {
        'clarification' {
            @{
                id       = "clarification-failure"
                question = "Clarification loop failed during task completion"
                fixLabel = "Inspect clarification-questions/answers and retry manually"
                fixRat   = "Review the questions/answers in the worktree and resolve before retry"
            }
        }
        'outputs' {
            @{
                id       = "outputs-validation-failure"
                question = "Task outputs validation failed"
                fixLabel = "Produce the missing outputs and retry manually"
                fixRat   = "Inspect the worktree to see which declared outputs are missing"
            }
        }
        'front_matter' {
            @{
                id       = "front-matter-failure"
                question = "JSON front-matter injection failed"
                fixLabel = "Repair the affected document and retry manually"
                fixRat   = "Inspect the worktree document(s) and fix front-matter blockers"
            }
        }
        default {
            @{
                id       = "post-script-failure"
                question = "post_script failed during task completion"
                fixLabel = "Fix the post_script and retry manually"
                fixRat   = "Inspect the worktree, repair the post_script, then retry the task"
            }
        }
    }

    $taskContent.pending_question = @{
        id             = $sourceMessaging.id
        question       = $sourceMessaging.question
        context        = $contextText
        options        = @(
            @{ key = "A"; label = $sourceMessaging.fixLabel; rationale = $sourceMessaging.fixRat }
            @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
        )
        recommendation = "A"
        asked_at       = (Get-Date).ToUniversalTime().ToString("o")
    }

    $newPath = Join-Path $needsInputDir $taskFile.Name
    Move-TaskFileAtomic -SourcePath $taskFile.FullName `
                        -TargetPath $newPath `
                        -Content $taskContent `
                        -Depth 20 `
                        -TaskId $taskContent.id

    return $true
}

<#
.SYNOPSIS
Task-runner wrapper that invokes a task's post_script (if any) and reports failure.

.DESCRIPTION
Used by both task-runner code paths in Invoke-WorkflowProcess.ps1 to avoid
duplicating the guard + try/catch + logging block. Returns $null on success or
when the task has no post_script; returns a string error message on failure,
leaving it to the caller to flip any success flag.
#>
function Invoke-TaskPostScriptIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$ProcessId
    )

    if (-not $Task.post_script) { return $null }

    try {
        Invoke-PostScript -BotRoot $BotRoot -ProductDir $ProductDir -Settings $Settings `
            -Model $Model -ProcessId $ProcessId -RawPostScript $Task.post_script
        return $null
    } catch {
        $msg = "post_script failed: $($_.Exception.Message)"
        Write-Status $msg -Type Error
        Write-ProcessActivity -Id $ProcessId -ActivityType "error" -Message "$($Task.name): $msg"
        return $msg
    }
}

#endregion

#region Merge-failure escalation
# Move a task from done/in-progress/needs-input to needs-input/ with a
# structured pending_question keyed to the underlying failure_kind, then
# (optionally) notify external stakeholders via Dotbot.Notification.
#
# Complete-TaskWorktree (Dotbot.Worktree) returns one of five failure kinds:
#   rebase_conflict        — git rebase aborted on real file conflicts
#   branch_missing         — task branch was deleted before merge ran
#   merge_command_failed   — `git merge --squash` returned non-zero (non-conflict)
#   commit_failed          — post-squash `git commit` was rejected (hooks, etc.)
#   exception              — unhandled exception during merge sequence
# Each kind drives a kind-specific pending_question (id, question text, context,
# options). Conflating them under "merge conflict" hid the real reason and
# offered useless option sets ("Resolve manually" doesn't apply when the
# branch never existed).

function New-MergeFailurePendingQuestion {
    <#
    .SYNOPSIS
    Build the pending_question payload for a merge failure, keyed by failure_kind.

    .DESCRIPTION
    Single source of truth for the kind → (id, question, context, options) mapping.
    Always includes the merge result message, the captured failure_detail (truncated),
    and the worktree path in context so operators can diagnose without grepping logs.
    #>
    param(
        [Parameter(Mandatory)] [string] $FailureKind,
        [string] $Message = "",
        [string] $FailureDetail = "",
        [string[]] $ConflictFiles = @(),
        [Parameter(Mandatory)] [string] $WorktreePath
    )

    $askedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Cap failure_detail so a 500-line git transcript doesn't bloat the JSON file
    # or the notification card. Operators get the first 1.5KB which contains the
    # actual error in every case observed so far.
    $detailExcerpt = if ($FailureDetail -and $FailureDetail.Length -gt 1500) {
        $FailureDetail.Substring(0, 1500) + "`n…(truncated)"
    } else {
        $FailureDetail
    }

    switch ($FailureKind) {
        'rebase_conflict' {
            $conflictDetail = if ($ConflictFiles.Count -gt 0) { $ConflictFiles -join '; ' } else { '(none reported)' }
            return @{
                id             = "merge-conflict"
                question       = "Merge conflict during squash-merge to main"
                context        = "Conflict details: $conflictDetail. Worktree preserved at: $WorktreePath"
                options        = @(
                    @{ key = "A"; label = "Resolve manually and retry (recommended)"; rationale = "Inspect the worktree, resolve conflicts, then retry merge" }
                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                    @{ key = "C"; label = "Retry with fresh rebase"; rationale = "Reset and attempt rebase again" }
                )
                recommendation = "A"
                asked_at       = $askedAt
            }
        }
        'branch_missing' {
            return @{
                id             = "branch-missing"
                question       = "Task branch no longer exists — cannot complete merge"
                context        = "$Message. $detailExcerpt. Worktree preserved at: $WorktreePath"
                options        = @(
                    @{ key = "A"; label = "Inspect worktree and decide (recommended)"; rationale = "Open the worktree to see what work was done, then decide" }
                    @{ key = "B"; label = "Discard task changes"; rationale = "Abandon this task — worktree removed, task closed" }
                )
                recommendation = "A"
                asked_at       = $askedAt
            }
        }
        'merge_command_failed' {
            return @{
                id             = "merge-failed"
                question       = "Squash-merge command failed during task completion"
                context        = "$Message`nGit output:`n$detailExcerpt`nWorktree preserved at: $WorktreePath"
                options        = @(
                    @{ key = "A"; label = "Investigate and retry (recommended)"; rationale = "Inspect main repo state, fix the underlying git issue, then retry merge" }
                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                    @{ key = "C"; label = "Retry merge"; rationale = "Re-run the squash-merge as-is (use only when the underlying issue is already fixed)" }
                )
                recommendation = "A"
                asked_at       = $askedAt
            }
        }
        'commit_failed' {
            return @{
                id             = "commit-failed"
                question       = "Commit after squash-merge was rejected"
                context        = "$Message. Commonly a pre-commit hook (secret scan, lint, conventional-commit gate).`nCommit output:`n$detailExcerpt`nWorktree preserved at: $WorktreePath"
                options        = @(
                    @{ key = "A"; label = "Fix in main repo and retry (recommended)"; rationale = "Address the hook output, then retry merge" }
                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                )
                recommendation = "A"
                asked_at       = $askedAt
            }
        }
        'exception' {
            return @{
                id             = "merge-error"
                question       = "Unexpected error during squash-merge to main"
                context        = "$Message`nDetail:`n$detailExcerpt`nWorktree preserved at: $WorktreePath"
                options        = @(
                    @{ key = "A"; label = "Investigate and retry (recommended)"; rationale = "Inspect activity.jsonl and the worktree, fix the root cause, then retry" }
                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                )
                recommendation = "A"
                asked_at       = $askedAt
            }
        }
        default {
            # Unknown / unspecified failure kind — surface whatever we have.
            return @{
                id             = "merge-error"
                question       = "Merge to main did not complete"
                context        = "$Message`n$detailExcerpt`nWorktree preserved at: $WorktreePath"
                options        = @(
                    @{ key = "A"; label = "Investigate and retry (recommended)"; rationale = "Inspect activity.jsonl and the worktree to determine cause" }
                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                )
                recommendation = "A"
                asked_at       = $askedAt
            }
        }
    }
}

function Move-TaskToMergeFailureNeedsInput {
    <#
    .SYNOPSIS
    Move a task from done/in-progress/needs-input to needs-input/ with a
    kind-aware merge-failure pending_question and dispatch an external
    notification when configured.

    .PARAMETER MergeResult
    Hashtable returned by Complete-TaskWorktree. Reads:
      failure_kind   — drives the pending_question template (see
                       New-MergeFailurePendingQuestion). When absent, falls back
                       to 'rebase_conflict' if conflict_files is non-empty,
                       otherwise 'unknown'. The fallback keeps older callers
                       and test fixtures working without modification.
      message        — human-readable summary, surfaced in pending_question.context
      failure_detail — captured git output / exception, surfaced (truncated) in context
      conflict_files — used only for the rebase_conflict template

    .PARAMETER BotRoot
    The `.bot` root directory (matches the convention used by WorktreeManager,
    Get-NotificationSettings, and the runtime process types). Defaults to
    `$global:DotbotProjectRoot/.bot`.

    .OUTPUTS
    @{ success; new_path; notified; notification_silent; notification_reason; source_status; failure_kind }
    notification_silent is $true when the project hasn't opted into notifications
    (no Dotbot.Notification module or settings.enabled = $false). source_status is
    the directory the task was found in (`done`, `in-progress`, `needs-review`,
    `needs-input`), or
    $null when the task was not found. failure_kind echoes the kind that drove
    the pending_question (post-fallback resolution).
    #>
    param(
        [Parameter(Mandatory)] [string] $TaskId,
        [Parameter(Mandatory)] [string] $TasksBaseDir,
        [Parameter(Mandatory)] [object] $MergeResult,
        [Parameter(Mandatory)] [string] $WorktreePath,
        [string] $BotRoot
    )

    if (-not $BotRoot) {
        if (-not $global:DotbotProjectRoot) {
            throw "Move-TaskToMergeFailureNeedsInput: BotRoot not provided and \$global:DotbotProjectRoot is not set"
        }
        $BotRoot = Get-DotbotProjectBotPath
    }

    $needsInputDir = Join-Path $TasksBaseDir "needs-input"

    # Look across done/, in-progress/, needs-review/, and needs-input/. The escalation handler
    # historically only checked done/ on the assumption that task_set_status(done) had
    # already moved the task there before the merge attempt. That assumption
    # breaks when a paused task or a still-in-progress task is routed here
    # (for example when a runner upstream of this helper misclassifies state).
    # Reporting the directory we found the task in keeps the escalation
    # diagnosable when callers cross-check.
    $sourceStatus = $null
    $taskFile = $null
    foreach ($status in @('done', 'in-progress', 'needs-review', 'needs-input')) {
        $dir = Join-Path $TasksBaseDir $status
        $candidate = Get-ChildItem -LiteralPath $dir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
            try {
                $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $c.id -eq $TaskId
            } catch { $false }
        } | Select-Object -First 1
        if ($candidate) {
            $taskFile = $candidate
            $sourceStatus = $status
            break
        }
    }

    if (-not $taskFile) {
        return @{
            success             = $false
            new_path            = $null
            notified            = $false
            notification_silent = $false
            notification_reason = "Task file not found in done/, in-progress/, or needs-input/"
            source_status       = $null
            failure_kind        = $null
        }
    }

    # Inline transition rather than Set-TaskState: this path runs AFTER
    # task_set_status(done) has already moved the task to done/, and the merge-failure
    # escalation needs to preserve the worktree, set a structured pending_question,
    # and close the open execution session in one cohesive block.
    $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
    $taskContent.status = 'needs-input'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("o")

    if (-not $taskContent.PSObject.Properties['pending_question']) {
        $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
    }

    # Extract merge-result fields tolerant of both [hashtable] (production shape)
    # and [PSCustomObject] (older test fixtures).
    $mr = @{ failure_kind = $null; message = ""; failure_detail = ""; conflict_files = @() }
    foreach ($field in @('failure_kind', 'message', 'failure_detail', 'conflict_files')) {
        $value = $null
        if ($MergeResult -is [hashtable]) {
            if ($MergeResult.ContainsKey($field)) { $value = $MergeResult[$field] }
        } elseif ($MergeResult.PSObject.Properties[$field]) {
            $value = $MergeResult.$field
        }
        if ($null -ne $value) { $mr[$field] = $value }
    }
    $conflictFiles = @($mr.conflict_files | Where-Object { $_ })

    # Resolve failure_kind. When Complete-TaskWorktree predates this contract or
    # a test fixture omits the field, infer from conflict_files presence. Anything
    # else with no conflict files becomes 'unknown' (template handles gracefully).
    $resolvedKind = if ($mr.failure_kind) {
        [string]$mr.failure_kind
    } elseif ($conflictFiles.Count -gt 0) {
        'rebase_conflict'
    } else {
        'unknown'
    }

    $taskContent.pending_question = New-MergeFailurePendingQuestion `
        -FailureKind $resolvedKind `
        -Message ([string]$mr.message) `
        -FailureDetail ([string]$mr.failure_detail) `
        -ConflictFiles $conflictFiles `
        -WorktreePath $WorktreePath

    # Close the open execution session by walking the task's history. The env var
    # $env:CLAUDE_SESSION_ID is nulled by both runtime workers before the merge,
    # so we cannot rely on it. Best-effort — never block escalation.
    try {
        if ((Get-Command Close-SessionOnTask -ErrorAction SilentlyContinue) -and $taskContent.PSObject.Properties['execution_sessions']) {
            $openSession = @($taskContent.execution_sessions) | Where-Object {
                $_ -and $_.id -and (-not $_.ended_at)
            } | Select-Object -Last 1
            if ($openSession) {
                Close-SessionOnTask -TaskContent $taskContent -SessionId $openSession.id -Phase 'execution'
            }
        }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Merge-failure session close failed" -Exception $_
        }
    }

    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }
    $newPath = Join-Path $needsInputDir $taskFile.Name
    if ($sourceStatus -eq 'needs-input') {
        # Already in the target directory — write in place.
        Write-TaskFileAtomic -Path $taskFile.FullName -Content $taskContent -Depth 20 -TaskId $taskContent.id
        $newPath = $taskFile.FullName
    } else {
        Move-TaskFileAtomic -SourcePath $taskFile.FullName `
                            -TargetPath $newPath `
                            -Content $taskContent `
                            -Depth 20 `
                            -TaskId $taskContent.id
    }

    $notified = $false
    $silent = $true
    $reason = "Notifications disabled"
    try {
        if (Get-Command Get-NotificationSettings -ErrorAction SilentlyContinue) {
            # Module is present — any failure past this point is a real delivery
            # problem, NOT a silent opt-out. Flip $silent here so the catch below
            # surfaces unexpected errors instead of masking them.
            $silent = $false
            $settings = Get-NotificationSettings -BotRoot $BotRoot
            if (-not $settings.enabled) {
                # Explicit opt-out via settings.
                $silent = $true
                $reason = "Notifications disabled"
            } else {
                $sendResult = Send-TaskNotification -TaskContent $taskContent -PendingQuestion $taskContent.pending_question
                if ($sendResult -and $sendResult.success) {
                    $taskContent | Add-Member -NotePropertyName 'notification' -NotePropertyValue @{
                        question_id = $sendResult.question_id
                        instance_id = $sendResult.instance_id
                        channel     = $sendResult.channel
                        project_id  = $sendResult.project_id
                        sent_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    } -Force
                    Write-TaskFileAtomic -Path $newPath -Content $taskContent -Depth 20 -TaskId $taskContent.id
                    $notified = $true
                    $reason = "Notification dispatched"
                } else {
                    $reason = if ($sendResult -and $sendResult.reason) { $sendResult.reason } else { "Send-TaskNotification failed" }
                }
            }
        } else {
            $reason = "Dotbot.Notification module not found"
        }
    } catch {
        $reason = "Notification error: $($_.Exception.Message)"
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Merge-failure notification failed" -Exception $_
        }
    }

    return @{
        success             = $true
        new_path            = $newPath
        notified            = $notified
        notification_silent = $silent
        notification_reason = $reason
        source_status       = $sourceStatus
        failure_kind        = $resolvedKind
    }
}

function Invoke-MergeFailureEscalation {
    <#
    .SYNOPSIS
    Runtime-side wrapper around Move-TaskToMergeFailureNeedsInput. Owns
    Write-Status / Write-ProcessActivity emission so each caller collapses
    to a single call. Emits messages keyed to the resolved failure_kind so the
    operator sees the actual reason in both the dashboard activity feed and
    the console.
    #>
    param(
        [Parameter(Mandatory)] [object] $Task,
        [Parameter(Mandatory)] [string] $TasksBaseDir,
        [Parameter(Mandatory)] [object] $MergeResult,
        [Parameter(Mandatory)] [string] $WorktreePath,
        [string] $ProcId,
        [string] $BotRoot
    )

    if (-not $BotRoot) {
        if (-not $global:DotbotProjectRoot) {
            throw "Invoke-MergeFailureEscalation: BotRoot not provided and \$global:DotbotProjectRoot is not set"
        }
        $BotRoot = Get-DotbotProjectBotPath
    }

    $emitActivity = {
        param($message)
        if ($ProcId -and (Get-Command Write-ProcessActivity -ErrorAction SilentlyContinue)) {
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message $message
        }
    }

    # Surface the underlying merge result for the operator BEFORE escalation
    # mutates state. activity.jsonl shows what actually failed; the needs-input
    # task pulls the same info into pending_question.context.
    $mrKind = if ($MergeResult -is [hashtable]) {
        if ($MergeResult.ContainsKey('failure_kind')) { [string]$MergeResult['failure_kind'] } else { '' }
    } elseif ($MergeResult -and $MergeResult.PSObject.Properties['failure_kind']) {
        [string]$MergeResult.failure_kind
    } else { '' }
    $mrMessage = if ($MergeResult -is [hashtable]) {
        if ($MergeResult.ContainsKey('message')) { [string]$MergeResult['message'] } else { '' }
    } elseif ($MergeResult -and $MergeResult.PSObject.Properties['message']) {
        [string]$MergeResult.message
    } else { '' }

    & $emitActivity ("Merge failed for {0} (kind={1}): {2}" -f $Task.name, ($(if($mrKind){$mrKind}else{'unknown'})), $mrMessage)

    $escalation = $null
    try {
        $escalation = Move-TaskToMergeFailureNeedsInput `
            -TaskId $Task.id `
            -TasksBaseDir $TasksBaseDir `
            -MergeResult $MergeResult `
            -WorktreePath $WorktreePath `
            -BotRoot $BotRoot
    } catch {
        $msg = "Merge-failure escalation helper failed: $($_.Exception.Message)"
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status $msg -Type Error
        }
        & $emitActivity "Escalation helper threw for $($Task.name): $($_.Exception.Message)"
        return @{
            success             = $false
            notified            = $false
            notification_silent = $false
            notification_reason = $msg
        }
    }

    if ($escalation -and $escalation.success) {
        $kindLabel = if ($escalation.failure_kind) { $escalation.failure_kind } else { 'unknown' }
        $statusMsg = if ($escalation.notified) {
            "Task moved to needs-input ($kindLabel); stakeholders notified"
        } else {
            "Task moved to needs-input ($kindLabel)"
        }
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status $statusMsg -Type Warn
        }
        & $emitActivity "Escalated merge failure ($kindLabel) for $($Task.name); notified=$($escalation.notified)"

        # Surface real delivery failures; opt-out states stay quiet.
        if (-not $escalation.notified -and -not $escalation.notification_silent) {
            if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
                Write-Status "Merge-failure notification not delivered: $($escalation.notification_reason)" -Type Warn
            }
            & $emitActivity "Merge-failure notification skipped for $($Task.name): $($escalation.notification_reason)"
        }
    } elseif ($escalation) {
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status "Failed to escalate merge failure: $($escalation.notification_reason)" -Type Error
        }
        & $emitActivity "Failed to escalate merge failure for $($Task.name): $($escalation.notification_reason)"
    } else {
        if (Get-Command Write-Status -ErrorAction SilentlyContinue) {
            Write-Status "Merge-failure escalation helper returned no result for $($Task.name)" -Type Error
        }
        & $emitActivity "Merge-failure escalation helper returned null for $($Task.name)"
        $escalation = @{
            success             = $false
            notified            = $false
            notification_silent = $false
            notification_reason = "Helper returned no result"
        }
    }

    return $escalation
}

#endregion

#region Interview loop (interview task type)
# Multi-round Q&A loop. Collects answers via local files
# (clarification-answers.json) or external Teams responses (when
# Dotbot.Notification is configured).


function Invoke-InterviewLoop {
    param(
        [string]$ProcessId,
        [hashtable]$ProcessData,
        [string]$BotRoot,
        [string]$ProductDir,
        [string]$UserPrompt,
        [switch]$ShowDebugJson,
        [switch]$ShowVerboseOutput,
        [string]$PermissionMode,
        [string]$Generator = 'dotbot-task-runner',
        [string]$TaskId
    )

    $processData = $ProcessData

    # Load interview prompt template
    $interviewWorkflowPath = Join-Path $BotRoot "recipes/prompts/00-interview.md"
    $interviewWorkflow = ""
    if (Test-Path $interviewWorkflowPath) {
        $interviewWorkflow = Get-Content $interviewWorkflowPath -Raw
    }

    # Check for briefing files
    $briefingDir = Join-Path $ProductDir "briefing"
    $interviewFileRefs = ""
    if (Test-Path $briefingDir) {
        $briefingFiles = Get-ChildItem -Path $briefingDir -File
        if ($briefingFiles.Count -gt 0) {
            $interviewFileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
            foreach ($bf in $briefingFiles) {
                $interviewFileRefs += "- $($bf.FullName)`n"
            }
        }
    }

    $interviewRound = 0
    $allQandA = @()
    $questionsPath = Join-Path $ProductDir "clarification-questions.json"
    # Per-process answers file so two concurrent interview tasks never read or
    # overwrite each other's answers. This loop is the authority on the path and
    # publishes it (product_dir/answers_path) onto the process file at the
    # needs-input flip, so the UI writer targets exactly this file.
    $answersPath   = Join-Path $ProductDir "clarification-answers.$ProcessId.json"
    $summaryPath   = Join-Path $ProductDir "interview-summary.md"

    # Use the highest-capability tier for interview quality.
    $interviewModel = 'best'

    do {
        $interviewRound++

        # Build previous Q&A context
        $previousContext = ""
        if ($allQandA.Count -gt 0) {
            $previousContext = "`n`n## Previous Interview Rounds`n"
            foreach ($round in $allQandA) {
                $previousContext += "`n### Round $($round.round)`n"
                foreach ($qa in $round.pairs) {
                    $previousContext += "**Q:** $($qa.question)`n**A:** $($qa.answer)`n`n"
                }
            }
        }

        $interviewPrompt = @"
$interviewWorkflow

## User's Project Description

$UserPrompt
$interviewFileRefs
$previousContext

## Instructions

Review all context above. Decide whether to write clarification-questions.json (more questions needed) or interview-summary.md (all clear). Write exactly one file to .bot/workspace/product/.
"@

        Write-Status "Interview round $interviewRound..." -Type Process
        Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound"

        $interviewSessionId = New-HarnessSession
        $streamArgs = @{
            Prompt = $interviewPrompt
            Model = $interviewModel
            SessionId = $interviewSessionId
            PersistSession = $false
        }
        if ($ShowDebugJson) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerboseOutput) { $streamArgs['ShowVerbose'] = $true }
        if ($PermissionMode) { $streamArgs['PermissionMode'] = $PermissionMode }

        Invoke-HarnessStream @streamArgs | Out-Null

        # Check what the interview pass wrote
        if (Test-Path $summaryPath) {
            Write-Status "Interview complete — summary written" -Type Complete
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview complete after $interviewRound round(s)"

            # Add JSON front matter to interview summary
            $meta = @{
                generated_at = (Get-Date).ToUniversalTime().ToString("o")
                model        = $interviewModel
                process_id   = $ProcessId
                phase        = "interview"
                generator    = $Generator
            }
            if ($TaskId) { $meta['task'] = "task-$TaskId" }
            Add-JsonFrontMatter -FilePath $summaryPath -Metadata $meta

            # Clean up any leftover question/answer files now that the interview is complete.
            Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
            Remove-Item $answersPath -Force -ErrorAction SilentlyContinue

            break
        }

        if (Test-Path $questionsPath) {
            try {
                if (-not (Get-Command Assert-TaskInputQuestionsData -ErrorAction SilentlyContinue)) {
                    Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.TaskInput" "Dotbot.TaskInput.psd1") -DisableNameChecking -Global
                }
                $questionsRaw = Get-Content $questionsPath -Raw
                $questionsData = $questionsRaw | ConvertFrom-Json
                Assert-TaskInputQuestionsData -QuestionsData $questionsData -Path 'clarification-questions.json'
                $questions = @($questionsData.questions)
            } catch {
                Write-Status "Invalid questions JSON: $($_.Exception.Message)" -Type Error
                throw "Invalid clarification-questions.json at '$questionsPath': $($_.Exception.Message)"
            }

            Write-Status "Round ${interviewRound}: $($questions.Count) question(s) — waiting for user" -Type Info

            # Set process to needs-input
            $processData.status = 'needs-input'
            $processData.pending_questions = $questionsData
            $processData.interview_round = $interviewRound
            # Publish where this run listens for answers so the UI writer targets
            # this run's (worktree-local, per-process) answers file rather than a
            # hardcoded main-checkout path — isolates concurrent interview tasks.
            $processData.product_dir = $ProductDir
            $processData.answers_path = $answersPath
            $processData.heartbeat_status = "Waiting for interview answers (round $interviewRound)"
            Write-ProcessFile -Id $ProcessId -Data $processData
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Waiting for user answers (round $interviewRound, $($questions.Count) questions)"

            # Send questions to external notification channel (Teams) if configured
            $interviewNotifications = @{}
            $interviewNotifSettings = $null
            try {
                if (Get-Command Get-NotificationSettings -ErrorAction SilentlyContinue) {
                    $interviewNotifSettings = Get-NotificationSettings -BotRoot $BotRoot
                    if ($interviewNotifSettings.enabled) {
                        $notifNamePrefix = if ($TaskId) { "Interview (task $TaskId)" } else { "Interview" }
                        $notifId = if ($TaskId) { "$ProcessId-interview-$TaskId" } else { "$ProcessId-interview" }
                        foreach ($q in $questions) {
                            $fakeTask = @{ id = $notifId; name = "$notifNamePrefix Round $interviewRound" }
                            $pendingQ = @{
                                id = "$($q.id)-r$interviewRound"
                                question = $q.question
                                context = $q.context
                                options = @($q.options | ForEach-Object { @{ key = $_.key; label = $_.label; rationale = $_.rationale } })
                                recommendation = $q.recommendation
                            }
                            $sendResult = Send-TaskNotification -TaskContent $fakeTask -PendingQuestion $pendingQ -Settings $interviewNotifSettings
                            if ($sendResult.success) {
                                $interviewNotifications[$q.id] = @{
                                    question_id = $sendResult.question_id
                                    instance_id = $sendResult.instance_id
                                    project_id  = $sendResult.project_id
                                }
                            }
                        }
                        Write-Status "Sent $($interviewNotifications.Count) question(s) to Teams" -Type Info
                    }
                }
            } catch {
                Write-Status "Notification send failed (non-fatal): $($_.Exception.Message)" -Type Warn
            }

            # Poll for answers file OR external Teams responses. Use the same
            # per-process path published to the process file above so the UI
            # writer and this poll agree (and concurrent interviews stay isolated).
            $answersPath = Join-Path $ProductDir "clarification-answers.$ProcessId.json"
            if (Test-Path $answersPath) { Remove-Item $answersPath -Force }
            $teamsAnswers = @{}
            $lastTeamsPoll = [datetime]::MinValue
            $teamsPollInterval = 10  # seconds between server polls

            while (-not (Test-Path $answersPath)) {
                if (Test-ProcessStopSignal -Id $ProcessId) {
                    Write-Status "Stop signal received during interview" -Type Error
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    $processData.pending_questions = $null
                    Write-ProcessFile -Id $ProcessId -Data $processData
                    throw "Process stopped by user during interview"
                }

                # Check for Teams responses if notifications were sent
                if ($interviewNotifications.Count -gt 0 -and ([datetime]::UtcNow - $lastTeamsPoll).TotalSeconds -ge $teamsPollInterval) {
                    $lastTeamsPoll = [datetime]::UtcNow
                    foreach ($qId in @($interviewNotifications.Keys)) {
                        if ($teamsAnswers.ContainsKey($qId)) { continue }
                        try {
                            $notif = $interviewNotifications[$qId]
                            $resp = Get-TaskNotificationResponse -Notification $notif -Settings $interviewNotifSettings
                            if ($resp) {
                                $attachDir = Join-Path $ProductDir "attachments/$qId"
                                $resolved = Resolve-NotificationAnswer -Response $resp -Settings $interviewNotifSettings -AttachDir $attachDir
                                if ($resolved) {
                                    $teamsAnswers[$qId] = $resolved
                                    Write-Status "Received Teams answer for $qId : $($resolved.answer)" -Type Info

                                    # Inbound decision funnel (issue #416): promote this
                                    # interview answer to a decision record. Best-effort --
                                    # the funnel swallows its own failures and this guard
                                    # keeps a polling tick alive if the module is absent.
                                    try {
                                        if (-not (Get-Command New-InboundDecision -ErrorAction SilentlyContinue)) {
                                            Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.Decision" "Dotbot.Decision.psd1") -DisableNameChecking -Global -ErrorAction Stop
                                        }
                                        $iq = $questions | Where-Object { "$($_.id)" -eq "$qId" } | Select-Object -First 1
                                        $iqType = if ($iq -and @($iq.options).Count -gt 0) { 'singleChoice' } else { 'freeText' }
                                        $null = New-InboundDecision -Source mothership -BotPath $BotRoot -Payload @{
                                            questionType   = $iqType
                                            questionText   = if ($iq) { "$($iq.question)" } else { $null }
                                            options        = if ($iq) { $iq.options } else { $null }
                                            answer         = "$($resolved.answer)"
                                            questionId     = "$($notif.question_id)"
                                            projectId      = "$($notif.project_id)"
                                            instanceId     = "$($notif.instance_id)"
                                            taskId         = $TaskId
                                            relatedTaskIds = if ($TaskId) { @($TaskId) } else { @() }
                                        }
                                    } catch {
                                        Write-BotLog -Level Warn -Message "Inbound decision funnel (interview) failed" -Exception $_
                                    }
                                }
                            }
                        } catch { Write-BotLog -Level Warn -Message "Teams polling attempt failed" -Exception $_ }
                    }

                    # If all questions answered via Teams, write the answers file
                    if ($teamsAnswers.Count -ge $questions.Count) {
                        $answersObj = @{
                            answers = @($questions | ForEach-Object {
                                $r = $teamsAnswers[$_.id]
                                $entry = @{ id = $_.id; question = $_.question; answer = $r.answer }
                                if ($r.attachments -and $r.attachments.Count -gt 0) { $entry['attachments'] = $r.attachments }
                                $entry
                            })
                            answered_via = "teams"
                        }
                        $answersObj | ConvertTo-Json -Depth 10 | Set-Content -Path $answersPath -Encoding UTF8
                        Write-Status "All $($questions.Count) answers received via Teams" -Type Complete
                        break
                    }
                }

                Start-Sleep -Seconds 2
            }

            # Read answers
            try {
                $answersRaw = Get-Content $answersPath -Raw
                $answersData = $answersRaw | ConvertFrom-Json
            } catch {
                Write-Status "Failed to parse answers JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            # Check if user skipped
            if ($answersData.skipped -eq $true) {
                Write-Status "User skipped interview" -Type Info
                Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "User skipped interview at round $interviewRound"
                # Clean up
                Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
                Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
                break
            }

            # Accumulate Q&A for next round
            $allQandA += @{
                round = $interviewRound
                pairs = @($answersData.answers)
            }

            Write-Status "Answers received for round $interviewRound" -Type Success
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Received answers for round $interviewRound"

            # Keep clarification-questions.json and clarification-answers.json intact so
            # Claude can read them in the next round when it processes the answers.
            # They will be overwritten (questions) or pre-cleared (answers, line below)
            # naturally when the next round begins.

            # Reset process status
            $processData.status = 'running'
            $processData.pending_questions = $null
            $processData.interview_round = $null
            $processData.heartbeat_status = "Processing interview answers"
            Write-ProcessFile -Id $ProcessId -Data $processData
        } else {
            # Neither file written — something went wrong, proceed without
            Write-Status "Interview round produced no output — proceeding" -Type Warn
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound produced no output — skipping"
            break
        }
    } while ($true)

    # Ensure status is running after interview
    $processData.status = 'running'
    $processData.pending_questions = $null
    $processData.interview_round = $null
    Write-ProcessFile -Id $ProcessId -Data $processData
}

#endregion

Export-ModuleMember -Function @(
    # Prompt building
    'Build-TaskPrompt'
    # Review decisions
    'Resolve-TaskReviewDecision'
    # Completion detection
    'Test-TaskCompletion'
    # State recovery
    'Reset-InProgressTasks'
    'Get-NeedsInputTasksInScope'
    'Reset-SkippedTasks'
    # Post-script hooks
    'Invoke-PostScript'
    'Invoke-PostScriptFailureEscalation'
    'Invoke-TaskPostScriptIfPresent'
    # Merge-failure escalation
    'Move-TaskToMergeFailureNeedsInput'
    'Invoke-MergeFailureEscalation'
    'New-MergeFailurePendingQuestion'
    # Interview loop
    'Invoke-InterviewLoop'

    # Defined in nested modules under Private/, re-exported here so the
    # manifest sees them.
    'New-DotbotNanoId'
    'New-TaskId'
    'New-WorkflowRunId'
    'Test-TaskId'
    'Test-WorkflowRunId'
    'Get-ShortId'
    'Get-TaskStatuses'
    'Test-TaskStatus'
    'Get-AllowedTransitions'
    'Test-TaskTransition'
    'Assert-TaskTransition'
    'Get-TaskInstanceSchemaVersion'
    'Get-TaskInstanceFields'
    'Test-TaskInstance'
    'Assert-TaskInstance'
    'New-TaskInstance'
    'ConvertTo-DotbotSlug'
    'Get-WorkflowRunLayout'
    'Get-RunTaskFilePath'
    'Get-StandaloneTaskLayout'
    'Get-TaskLayoutPath'
)
