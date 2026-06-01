<#
.SYNOPSIS
Task-scoped handoff artifacts for human-in-the-loop pauses.

.DESCRIPTION
Dotbot does not create child tasks merely because a provider session must stop
for human input. A task writes a compact handoff before entering needs-input;
after the human answer, the same task starts a new session attempt from that
validated handoff.
#>

if (-not (Get-Module Dotbot.Worktree)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.Worktree" "Dotbot.Worktree.psd1") -DisableNameChecking -Global -ErrorAction SilentlyContinue
}

function Get-DotbotHandoffProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Set-DotbotHandoffProp {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function ConvertTo-DotbotHandoffArray {
    param($Value)
    if ($null -eq $Value) { return ,@() }
    return ,@($Value)
}

function Get-DotbotHandoffTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function ConvertTo-DotbotHandoffSegment {
    param(
        [string]$Value,
        [string]$Fallback = 'unknown'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = $Fallback }
    $segment = ($Value -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($segment)) { return $Fallback }
    return $segment
}

function Get-DotbotHandoffRunnerBag {
    param([Parameter(Mandatory)] $TaskContent)

    $extensions = Get-DotbotHandoffProp -Object $TaskContent -Name 'extensions'
    if (-not $extensions) {
        $extensions = [ordered]@{}
        Set-DotbotHandoffProp -Object $TaskContent -Name 'extensions' -Value $extensions
    }

    $runner = Get-DotbotHandoffProp -Object $extensions -Name 'runner'
    if (-not $runner) {
        $runner = [ordered]@{}
        Set-DotbotHandoffProp -Object $extensions -Name 'runner' -Value $runner
    }

    return $runner
}

function Get-DotbotHandoffRunId {
    param([Parameter(Mandatory)] $TaskContent)

    $provenance = Get-DotbotHandoffProp -Object $TaskContent -Name 'provenance'
    $runId = Get-DotbotHandoffProp -Object $provenance -Name 'run_id'
    if ([string]::IsNullOrWhiteSpace([string]$runId)) { return 'standalone' }
    return [string]$runId
}

function Get-DotbotHandoffWorktreeInfo {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$BotRoot
    )

    if (Get-Command Get-TaskWorktreeInfo -ErrorAction SilentlyContinue) {
        try {
            $info = Get-TaskWorktreeInfo -TaskId $TaskId -BotRoot $BotRoot
            if ($info) { return $info }
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message "Could not resolve handoff worktree info for task $TaskId" -Exception $_
            }
        }
    }
    return $null
}

function Resolve-DotbotHandoffBasePath {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$BotRoot,
        [string]$WorktreePath
    )

    if ($WorktreePath -and (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
        return [System.IO.Path]::GetFullPath($WorktreePath)
    }

    $info = Get-DotbotHandoffWorktreeInfo -TaskId $TaskId -BotRoot $BotRoot
    $mappedWorktree = Get-DotbotHandoffProp -Object $info -Name 'worktree_path'
    if ($mappedWorktree -and (Test-Path -LiteralPath $mappedWorktree -PathType Container)) {
        return [System.IO.Path]::GetFullPath([string]$mappedWorktree)
    }

    return [System.IO.Path]::GetFullPath((Split-Path -Parent $BotRoot))
}

function Get-DotbotHandoffBranchName {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$BasePath,
        [string]$BranchName
    )

    if ($BranchName) { return $BranchName }

    $info = Get-DotbotHandoffWorktreeInfo -TaskId $TaskId -BotRoot $BotRoot
    $mappedBranch = Get-DotbotHandoffProp -Object $info -Name 'branch_name'
    if ($mappedBranch) { return [string]$mappedBranch }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $branch = git -C $BasePath symbolic-ref --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch) { return [string]$branch }
    }
    return $null
}

function Get-NextDotbotTaskAttemptId {
    param([Parameter(Mandatory)] $RunnerBag)

    $active = [string](Get-DotbotHandoffProp -Object $RunnerBag -Name 'active_attempt_id')
    if ($active) { return $active }

    $attempts = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $RunnerBag -Name 'session_attempts')
    $next = $attempts.Count + 1
    return ('a{0:00}' -f $next)
}

function Get-NextDotbotTaskResumeAttemptId {
    param([Parameter(Mandatory)] $RunnerBag)

    $attempts = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $RunnerBag -Name 'session_attempts')
    $max = 0
    foreach ($attempt in $attempts) {
        $id = [string](Get-DotbotHandoffProp -Object $attempt -Name 'attempt_id')
        if ($id -match '^a(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -gt $max) { $max = $n }
        }
    }
    $active = [string](Get-DotbotHandoffProp -Object $RunnerBag -Name 'active_attempt_id')
    if ($active -match '^a(\d+)$') {
        $n = [int]$Matches[1]
        if ($n -gt $max) { $max = $n }
    }
    return ('a{0:00}' -f ($max + 1))
}

function Write-DotbotHandoffFile {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Content
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-DotbotHandoffJson {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Content
    )
    Write-DotbotHandoffFile -Path $Path -Content ($Content | ConvertTo-Json -Depth 30)
}

function Resolve-DotbotHandoffQuestion {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] $RunnerBag,
        [string]$QuestionId,
        [string]$Question,
        [string]$Context
    )

    $pendingQuestion = Get-DotbotHandoffProp -Object $RunnerBag -Name 'pending_question'
    if (-not $pendingQuestion) { $pendingQuestion = Get-DotbotHandoffProp -Object $TaskContent -Name 'pending_question' }

    $pendingQuestions = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $RunnerBag -Name 'pending_questions')
    if ($pendingQuestions.Count -eq 0) {
        $pendingQuestions = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $TaskContent -Name 'pending_questions')
    }

    $selected = $null
    if ($QuestionId -and $pendingQuestions.Count -gt 0) {
        $selected = @($pendingQuestions | Where-Object { [string](Get-DotbotHandoffProp -Object $_ -Name 'id') -eq $QuestionId }) | Select-Object -First 1
    }
    if (-not $selected -and $pendingQuestion) { $selected = $pendingQuestion }
    if (-not $selected -and $pendingQuestions.Count -gt 0) { $selected = $pendingQuestions[0] }

    $resolvedId = if ($QuestionId) { $QuestionId } else { [string](Get-DotbotHandoffProp -Object $selected -Name 'id') }
    $resolvedQuestion = if ($Question) { $Question } else { [string](Get-DotbotHandoffProp -Object $selected -Name 'question') }
    $resolvedContext = if ($Context) { $Context } else { [string](Get-DotbotHandoffProp -Object $selected -Name 'context') }

    if ([string]::IsNullOrWhiteSpace($resolvedId)) { $resolvedId = 'question' }
    if ([string]::IsNullOrWhiteSpace($resolvedQuestion)) { $resolvedQuestion = 'Task requires human input before it can continue.' }

    return @{
        id = $resolvedId
        question = $resolvedQuestion
        context = $resolvedContext
    }
}

function Get-DotbotHandoffBatchQuestionIds {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] $RunnerBag
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    $pendingQuestions = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $RunnerBag -Name 'pending_questions')
    if ($pendingQuestions.Count -eq 0) {
        $pendingQuestions = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $TaskContent -Name 'pending_questions')
    }
    foreach ($question in $pendingQuestions) {
        $id = [string](Get-DotbotHandoffProp -Object $question -Name 'id')
        if (-not [string]::IsNullOrWhiteSpace($id) -and -not $ids.Contains($id)) {
            $ids.Add($id) | Out-Null
        }
    }

    $resolvedQuestions = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $RunnerBag -Name 'questions_resolved')
    foreach ($question in $resolvedQuestions) {
        $id = [string](Get-DotbotHandoffProp -Object $question -Name 'id')
        if ([string]::IsNullOrWhiteSpace($id)) {
            $id = [string](Get-DotbotHandoffProp -Object $question -Name 'question_id')
        }
        if (-not [string]::IsNullOrWhiteSpace($id) -and -not $ids.Contains($id)) {
            $ids.Add($id) | Out-Null
        }
    }

    return @($ids)
}

function Get-DotbotHandoffNotesMarkdown {
    param($RunnerBag)

    $notes = Get-DotbotHandoffProp -Object $RunnerBag -Name 'handoff_notes'
    if (-not $notes) { return "" }

    if ($notes -is [string]) {
        if ([string]::IsNullOrWhiteSpace($notes)) { return "" }
        return "## Agent Handoff Notes`n`n$notes`n"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## Agent Handoff Notes") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($prop in @('already_done','files_changed','tests_run','open_risks','next_steps','stale_conditions')) {
        $value = Get-DotbotHandoffProp -Object $notes -Name $prop
        if (-not $value) { continue }
        $label = ($prop -replace '_', ' ')
        $lines.Add("### $label") | Out-Null
        foreach ($item in @(ConvertTo-DotbotHandoffArray $value)) {
            $lines.Add("- $item") | Out-Null
        }
        $lines.Add("") | Out-Null
    }
    return ($lines -join "`n")
}

function Get-DotbotHandoffGitStatus {
    param([string]$BasePath)

    if (-not $BasePath -or -not (Test-Path -LiteralPath $BasePath -PathType Container)) { return @() }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
    $status = @(git -C $BasePath status --short 2>$null | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { return @() }
    return $status
}

function New-DotbotTaskHandoff {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [string]$BotRoot,
        [string]$QuestionId,
        [string]$Question,
        [string]$Context,
        [string]$Reason = 'human-input',
        [string]$WorktreePath,
        [string]$BranchName
    )

    $taskId = [string](Get-DotbotHandoffProp -Object $TaskContent -Name 'id')
    if ([string]::IsNullOrWhiteSpace($taskId)) { throw "Cannot create handoff for task without id" }

    $runner = Get-DotbotHandoffRunnerBag -TaskContent $TaskContent
    $runId = Get-DotbotHandoffRunId -TaskContent $TaskContent
    $attemptId = Get-NextDotbotTaskAttemptId -RunnerBag $runner
    $basePath = Resolve-DotbotHandoffBasePath -TaskId $taskId -BotRoot $BotRoot -WorktreePath $WorktreePath
    $branch = Get-DotbotHandoffBranchName -TaskId $taskId -BotRoot $BotRoot -BasePath $basePath -BranchName $BranchName

    $questionInfo = Resolve-DotbotHandoffQuestion -TaskContent $TaskContent -RunnerBag $runner -QuestionId $QuestionId -Question $Question -Context $Context
    $batchQuestionIds = Get-DotbotHandoffBatchQuestionIds -TaskContent $TaskContent -RunnerBag $runner
    $timestamp = Get-DotbotHandoffTimestamp

    $runSegment = ConvertTo-DotbotHandoffSegment -Value $runId -Fallback 'standalone'
    $taskSegment = ConvertTo-DotbotHandoffSegment -Value $taskId -Fallback 'task'
    $attemptSegment = ConvertTo-DotbotHandoffSegment -Value $attemptId -Fallback 'a01'
    $handoffId = "ho_${runSegment}_${taskSegment}_${attemptSegment}_$($timestamp -replace '[^0-9TZ]', '')"

    $relativeDir = ".bot/.handoffs/$runSegment/$taskSegment/$attemptSegment"
    $handoffDir = Join-Path $basePath $relativeDir
    $manifestPath = Join-Path $handoffDir 'manifest.json'
    $documentPath = Join-Path $handoffDir 'handoff.md'
    $relativeManifest = "$relativeDir/manifest.json"
    $relativeDocument = "$relativeDir/handoff.md"

    $statusLines = Get-DotbotHandoffGitStatus -BasePath $basePath
    $statusText = if ($statusLines.Count -gt 0) { ($statusLines | ForEach-Object { "- $_" }) -join "`n" } else { "- No git status output captured." }
    $notesText = Get-DotbotHandoffNotesMarkdown -RunnerBag $runner
    $taskName = [string](Get-DotbotHandoffProp -Object $TaskContent -Name 'name')

    $markdown = @"
# Task Handoff

Read this first. Continue the same task from this state after the human answer. Do not rediscover the task from scratch unless the stale conditions below say this handoff is invalid.

## Identity

- Task: $taskId - $taskName
- Run: $runId
- Attempt: $attemptId
- Handoff: $handoffId
- Reason: $Reason
- Worktree: $basePath
- Branch: $branch
- Created: $timestamp

## Human Input Needed

- Question ID: $($questionInfo.id)
- Question: $($questionInfo.question)

## Context

$($questionInfo.context)

$notesText
## Current Worktree State

$statusText

## Next Session Bootstrap

1. Read the answer recorded on this same task.
2. Trust this handoff unless files listed above changed outside the task or the answer contradicts the recorded next steps.
3. Continue the same task in the same worktree and branch.
4. Keep exploration targeted to the files needed for the next concrete step.
"@

    $manifest = [ordered]@{
        handoff_id = $handoffId
        run_id = $runId
        task_id = $taskId
        attempt_id = $attemptId
        worktree_path = $basePath
        branch_name = $branch
        question_id = $questionInfo.id
        question_ids = @($batchQuestionIds)
        reason = $Reason
        status = 'open'
        created_at = $timestamp
        consumed_at = $null
        consumed_by_attempt_id = $null
        manifest_path = $relativeManifest
        document_path = $relativeDocument
    }

    Write-DotbotHandoffFile -Path $documentPath -Content $markdown
    Write-DotbotHandoffJson -Path $manifestPath -Content $manifest

    $reference = [ordered]@{
        handoff_id = $handoffId
        manifest_path = $relativeManifest
        document_path = $relativeDocument
        attempt_id = $attemptId
        status = 'open'
        created_at = $timestamp
    }
    Set-DotbotHandoffProp -Object $runner -Name 'current_handoff' -Value $reference

    $history = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $runner -Name 'handoffs')
    $history += [pscustomobject]$reference
    Set-DotbotHandoffProp -Object $runner -Name 'handoffs' -Value $history

    $attempts = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $runner -Name 'session_attempts')
    $existing = @($attempts | Where-Object { [string](Get-DotbotHandoffProp -Object $_ -Name 'attempt_id') -eq $attemptId }) | Select-Object -First 1
    if ($existing) {
        Set-DotbotHandoffProp -Object $existing -Name 'ended_at' -Value $timestamp
        Set-DotbotHandoffProp -Object $existing -Name 'ended_reason' -Value 'needs-input'
        Set-DotbotHandoffProp -Object $existing -Name 'handoff_id' -Value $handoffId
    } else {
        $attempts += [pscustomobject][ordered]@{
            attempt_id = $attemptId
            started_at = $null
            ended_at = $timestamp
            ended_reason = 'needs-input'
            handoff_id = $handoffId
        }
        Set-DotbotHandoffProp -Object $runner -Name 'session_attempts' -Value $attempts
    }

    return [pscustomobject]@{
        success = $true
        handoff = [pscustomobject]$reference
        manifest = [pscustomobject]$manifest
        base_path = $basePath
    }
}

function Resolve-DotbotTaskHandoffReference {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [string]$BotRoot
    )

    $taskId = [string](Get-DotbotHandoffProp -Object $TaskContent -Name 'id')
    $runner = Get-DotbotHandoffRunnerBag -TaskContent $TaskContent
    $reference = Get-DotbotHandoffProp -Object $runner -Name 'current_handoff'
    if (-not $reference) { return $null }

    $basePath = Resolve-DotbotHandoffBasePath -TaskId $taskId -BotRoot $BotRoot
    $manifestRel = [string](Get-DotbotHandoffProp -Object $reference -Name 'manifest_path')
    if ([string]::IsNullOrWhiteSpace($manifestRel)) { throw "Task $taskId has current_handoff without manifest_path" }
    $manifestPath = Join-Path $basePath $manifestRel

    $resolvedBase = [System.IO.Path]::GetFullPath($basePath)
    $resolvedManifest = [System.IO.Path]::GetFullPath($manifestPath)
    if (-not $resolvedManifest.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Task $taskId handoff manifest resolves outside its worktree"
    }
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw "Task $taskId handoff manifest not found: $manifestRel"
    }

    $manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
    if ([string](Get-DotbotHandoffProp -Object $manifest -Name 'task_id') -ne $taskId) {
        throw "Task $taskId handoff manifest belongs to task '$((Get-DotbotHandoffProp -Object $manifest -Name 'task_id'))'"
    }
    $runId = Get-DotbotHandoffRunId -TaskContent $TaskContent
    if ([string](Get-DotbotHandoffProp -Object $manifest -Name 'run_id') -ne $runId) {
        throw "Task $taskId handoff manifest run mismatch"
    }

    $documentRel = [string](Get-DotbotHandoffProp -Object $manifest -Name 'document_path')
    if ([string]::IsNullOrWhiteSpace($documentRel)) {
        $documentRel = [string](Get-DotbotHandoffProp -Object $reference -Name 'document_path')
    }
    $documentPath = if ($documentRel) { Join-Path $basePath $documentRel } else { $null }
    if ($documentPath) {
        $resolvedDoc = [System.IO.Path]::GetFullPath($documentPath)
        if (-not $resolvedDoc.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Task $taskId handoff document resolves outside its worktree"
        }
    }

    return @{
        runner = $runner
        reference = $reference
        manifest = $manifest
        manifest_path = $resolvedManifest
        document_path = $documentPath
        base_path = $basePath
    }
}

function Complete-DotbotTaskHandoffForAnswer {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$QuestionId,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Answer,
        [Parameter(Mandatory)] [string]$AnsweredAt,
        [ValidateSet('consumed','superseded')] [string]$Disposition = 'consumed'
    )

    $taskId = [string](Get-DotbotHandoffProp -Object $TaskContent -Name 'id')
    $resolved = Resolve-DotbotTaskHandoffReference -TaskContent $TaskContent -BotRoot $BotRoot
    if (-not $resolved) {
        return @{ success = $true; skipped = $true; reason = 'no_current_handoff' }
    }

    $manifest = $resolved.manifest
    $status = [string](Get-DotbotHandoffProp -Object $manifest -Name 'status')
    if ($status -and $status -ne 'open') {
        throw "Task $taskId handoff is not open (status: $status)"
    }
    $manifestQuestionId = [string](Get-DotbotHandoffProp -Object $manifest -Name 'question_id')
    if ($manifestQuestionId -and $QuestionId -and $manifestQuestionId -ne $QuestionId -and $manifestQuestionId -ne 'question') {
        $knownQuestionIds = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $manifest -Name 'question_ids')
        if ($knownQuestionIds.Count -eq 0) {
            $knownQuestionIds = Get-DotbotHandoffBatchQuestionIds -TaskContent $TaskContent -RunnerBag $resolved.runner
        }
        if ($QuestionId -notin @($knownQuestionIds)) {
            throw "Task $taskId answer question '$QuestionId' does not match handoff question '$manifestQuestionId'"
        }
    }

    $runner = $resolved.runner
    $nextAttemptId = if ($Disposition -eq 'consumed') { Get-NextDotbotTaskResumeAttemptId -RunnerBag $runner } else { $null }
    Set-DotbotHandoffProp -Object $manifest -Name 'status' -Value $Disposition
    Set-DotbotHandoffProp -Object $manifest -Name 'consumed_at' -Value $AnsweredAt
    Set-DotbotHandoffProp -Object $manifest -Name 'consumed_by_attempt_id' -Value $nextAttemptId
    Write-DotbotHandoffJson -Path $resolved.manifest_path -Content $manifest

    $resumeContext = [ordered]@{
        resume_reason = 'human-input'
        handoff_id = [string](Get-DotbotHandoffProp -Object $manifest -Name 'handoff_id')
        previous_attempt_id = [string](Get-DotbotHandoffProp -Object $manifest -Name 'attempt_id')
        next_attempt_id = $nextAttemptId
        manifest_path = [string](Get-DotbotHandoffProp -Object $manifest -Name 'manifest_path')
        document_path = [string](Get-DotbotHandoffProp -Object $manifest -Name 'document_path')
        question_id = $QuestionId
        answer = $Answer
        answered_at = $AnsweredAt
    }

    if ($Disposition -eq 'consumed') {
        Set-DotbotHandoffProp -Object $runner -Name 'resume_context' -Value $resumeContext
        Set-DotbotHandoffProp -Object $runner -Name 'active_attempt_id' -Value $nextAttemptId
    }
    Set-DotbotHandoffProp -Object $runner -Name 'current_handoff' -Value $null

    return @{
        success = $true
        skipped = $false
        disposition = $Disposition
        resume_context = [pscustomobject]$resumeContext
    }
}

function Get-DotbotTaskResumeContext {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [string]$BotRoot
    )

    $runner = Get-DotbotHandoffRunnerBag -TaskContent $TaskContent
    $resume = Get-DotbotHandoffProp -Object $runner -Name 'resume_context'
    if (-not $resume) { return $null }

    $taskId = [string](Get-DotbotHandoffProp -Object $TaskContent -Name 'id')
    $basePath = Resolve-DotbotHandoffBasePath -TaskId $taskId -BotRoot $BotRoot
    $documentRel = [string](Get-DotbotHandoffProp -Object $resume -Name 'document_path')
    $manifestRel = [string](Get-DotbotHandoffProp -Object $resume -Name 'manifest_path')
    $documentText = $null
    $manifest = $null

    if ($documentRel) {
        $docPath = Join-Path $basePath $documentRel
        $resolvedBase = [System.IO.Path]::GetFullPath($basePath)
        $resolvedDoc = [System.IO.Path]::GetFullPath($docPath)
        if ($resolvedDoc.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedDoc -PathType Leaf)) {
            $documentText = Get-Content -LiteralPath $resolvedDoc -Raw
        }
    }
    if ($manifestRel) {
        $manifestPath = Join-Path $basePath $manifestRel
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
    }

    return [pscustomobject][ordered]@{
        resume_reason = Get-DotbotHandoffProp -Object $resume -Name 'resume_reason'
        handoff_id = Get-DotbotHandoffProp -Object $resume -Name 'handoff_id'
        previous_attempt_id = Get-DotbotHandoffProp -Object $resume -Name 'previous_attempt_id'
        next_attempt_id = Get-DotbotHandoffProp -Object $resume -Name 'next_attempt_id'
        manifest_path = $manifestRel
        document_path = $documentRel
        question_id = Get-DotbotHandoffProp -Object $resume -Name 'question_id'
        answer = Get-DotbotHandoffProp -Object $resume -Name 'answer'
        answered_at = Get-DotbotHandoffProp -Object $resume -Name 'answered_at'
        manifest = $manifest
        handoff_markdown = $documentText
    }
}

function Start-DotbotTaskSessionAttempt {
    param(
        [Parameter(Mandatory)] $TaskContent,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProviderSessionId
    )

    $normalizedProviderSessionId = if ([string]::IsNullOrWhiteSpace($ProviderSessionId)) { $null } else { $ProviderSessionId }
    $runner = Get-DotbotHandoffRunnerBag -TaskContent $TaskContent
    $attemptId = [string](Get-DotbotHandoffProp -Object $runner -Name 'active_attempt_id')
    if (-not $attemptId) {
        $attemptId = Get-NextDotbotTaskAttemptId -RunnerBag $runner
        Set-DotbotHandoffProp -Object $runner -Name 'active_attempt_id' -Value $attemptId
    }

    $attempts = ConvertTo-DotbotHandoffArray (Get-DotbotHandoffProp -Object $runner -Name 'session_attempts')
    $existing = @($attempts | Where-Object { [string](Get-DotbotHandoffProp -Object $_ -Name 'attempt_id') -eq $attemptId }) | Select-Object -First 1
    $now = Get-DotbotHandoffTimestamp
    if ($existing) {
        if (-not (Get-DotbotHandoffProp -Object $existing -Name 'started_at')) {
            Set-DotbotHandoffProp -Object $existing -Name 'started_at' -Value $now
        }
        Set-DotbotHandoffProp -Object $existing -Name 'provider_session_id' -Value $normalizedProviderSessionId
        Set-DotbotHandoffProp -Object $existing -Name 'status' -Value 'running'
    } else {
        $attempts += [pscustomobject][ordered]@{
            attempt_id = $attemptId
            provider_session_id = $normalizedProviderSessionId
            started_at = $now
            ended_at = $null
            ended_reason = $null
            status = 'running'
            handoff_id = $null
        }
        Set-DotbotHandoffProp -Object $runner -Name 'session_attempts' -Value $attempts
    }

    return [pscustomobject]@{
        attempt_id = $attemptId
        provider_session_id = $normalizedProviderSessionId
    }
}

Export-ModuleMember -Function @(
    'New-DotbotTaskHandoff',
    'Complete-DotbotTaskHandoffForAnswer',
    'Get-DotbotTaskResumeContext',
    'Start-DotbotTaskSessionAttempt'
)
