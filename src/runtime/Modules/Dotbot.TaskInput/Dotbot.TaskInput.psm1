<#
.SYNOPSIS
Shared in-process transitions for human input on tasks.

.DESCRIPTION
Gives every surface that accepts human input a single runtime-owned place to
mutate task files, using the same atomic task-file primitives as the rest of
the runtime.
#>

if (-not (Get-Module Dotbot.TaskFile)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.TaskFile" "Dotbot.TaskFile.psd1") -DisableNameChecking -Global
}
if (-not (Get-Module Dotbot.Task)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.Task" "Dotbot.Task.psd1") -DisableNameChecking -Global
}
if (-not (Get-Module Dotbot.Worktree)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.Worktree" "Dotbot.Worktree.psd1") -DisableNameChecking -Global -ErrorAction SilentlyContinue
}
if (-not (Get-Module Dotbot.Handoff)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Dotbot.Handoff" "Dotbot.Handoff.psd1") -DisableNameChecking -Global
}

function Get-TaskInputProp {
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

function Set-TaskInputProp {
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

function Remove-TaskInputProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { $Object.Remove($Name) }
        return
    }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Test-TaskInputHasProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function ConvertTo-TaskInputArray {
    param($Value)
    if ($null -eq $Value) { return ,@() }
    return ,@($Value)
}

function Add-TaskInputValidationError {
    param(
        [System.Collections.ArrayList]$Errors,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Message
    )
    [void]$Errors.Add("${Path}: $Message")
}

function Test-TaskInputQuestionObject {
    param(
        [Parameter(Mandatory)] $Question,
        [Parameter(Mandatory)] [string]$Path,
        [System.Collections.ArrayList]$Errors
    )

    if ($Question -isnot [System.Collections.IDictionary] -and $Question -isnot [PSCustomObject]) {
        Add-TaskInputValidationError -Errors $Errors -Path $Path -Message 'must be an object'
        return
    }

    $questionText = [string](Get-TaskInputProp -Object $Question -Name 'question')
    if ([string]::IsNullOrWhiteSpace($questionText)) {
        Add-TaskInputValidationError -Errors $Errors -Path "$Path.question" -Message 'is required'
    }

    if (-not (Test-TaskInputHasProp -Object $Question -Name 'options')) {
        Add-TaskInputValidationError -Errors $Errors -Path "$Path.options" -Message 'is required; do not inline choices in question text'
        return
    }

    $optionsValue = Get-TaskInputProp -Object $Question -Name 'options'
    $options = ConvertTo-TaskInputArray $optionsValue
    if ($options.Count -lt 2) {
        Add-TaskInputValidationError -Errors $Errors -Path "$Path.options" -Message 'must include at least two structured options'
        return
    }
    if ($options.Count -gt 5) {
        Add-TaskInputValidationError -Errors $Errors -Path "$Path.options" -Message 'must include no more than five options'
    }

    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $options.Count; $i++) {
        $optionPath = "$Path.options[$i]"
        $option = $options[$i]
        if ($option -isnot [System.Collections.IDictionary] -and $option -isnot [PSCustomObject]) {
            Add-TaskInputValidationError -Errors $Errors -Path $optionPath -Message 'must be an object'
            continue
        }

        $key = [string](Get-TaskInputProp -Object $option -Name 'key')
        if ($key -cnotmatch '^[A-E]$') {
            Add-TaskInputValidationError -Errors $Errors -Path "$optionPath.key" -Message "must be one of A, B, C, D, or E"
        } elseif (-not $seenKeys.Add($key)) {
            Add-TaskInputValidationError -Errors $Errors -Path "$optionPath.key" -Message "duplicates option key '$key'"
        }

        $label = [string](Get-TaskInputProp -Object $option -Name 'label')
        if ([string]::IsNullOrWhiteSpace($label)) {
            Add-TaskInputValidationError -Errors $Errors -Path "$optionPath.label" -Message 'is required'
        }
    }

    $recommendation = [string](Get-TaskInputProp -Object $Question -Name 'recommendation')
    if (-not [string]::IsNullOrWhiteSpace($recommendation) -and -not $seenKeys.Contains($recommendation)) {
        Add-TaskInputValidationError -Errors $Errors -Path "$Path.recommendation" -Message "must match one of the option keys"
    }
}

function Test-TaskInputQuestionsData {
    param(
        [Parameter(Mandatory)] $QuestionsData,
        [string]$Path = 'questions'
    )

    $errors = [System.Collections.ArrayList]::new()
    if ($QuestionsData -isnot [System.Collections.IDictionary] -and $QuestionsData -isnot [PSCustomObject]) {
        Add-TaskInputValidationError -Errors $errors -Path $Path -Message 'payload must be an object'
        return $errors.ToArray()
    }

    if (-not (Test-TaskInputHasProp -Object $QuestionsData -Name 'questions')) {
        Add-TaskInputValidationError -Errors $errors -Path "$Path.questions" -Message 'is required'
        return $errors.ToArray()
    }

    $questions = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $QuestionsData -Name 'questions')
    if ($questions.Count -eq 0) {
        Add-TaskInputValidationError -Errors $errors -Path "$Path.questions" -Message 'must include at least one question'
        return $errors.ToArray()
    }

    for ($i = 0; $i -lt $questions.Count; $i++) {
        Test-TaskInputQuestionObject -Question $questions[$i] -Path "$Path.questions[$i]" -Errors $errors
    }

    return $errors.ToArray()
}

function Assert-TaskInputQuestionsData {
    param(
        [Parameter(Mandatory)] $QuestionsData,
        [string]$Path = 'questions'
    )

    $errors = @(Test-TaskInputQuestionsData -QuestionsData $QuestionsData -Path $Path)
    if ($errors.Count -gt 0) {
        throw "Invalid question payload: $($errors -join '; ')"
    }
}

function Test-TaskInputQuestionPayload {
    param(
        [Parameter(Mandatory)] $TaskContent
    )

    $errors = [System.Collections.ArrayList]::new()
    $containers = @()

    $extensions = Get-TaskInputProp -Object $TaskContent -Name 'extensions'
    if ($extensions) {
        $runner = Get-TaskInputProp -Object $extensions -Name 'runner'
        if ($runner) { $containers += @{ Value = $runner; Path = 'extensions.runner' } }
    }
    $containers += @{ Value = $TaskContent; Path = 'task' }

    foreach ($container in $containers) {
        $value = $container.Value
        $path = $container.Path

        if (Test-TaskInputHasProp -Object $value -Name 'pending_question') {
            $pendingQuestion = Get-TaskInputProp -Object $value -Name 'pending_question'
            if ($null -ne $pendingQuestion) {
                Test-TaskInputQuestionObject -Question $pendingQuestion -Path "$path.pending_question" -Errors $errors
            }
        }

        if (Test-TaskInputHasProp -Object $value -Name 'pending_questions') {
            $pendingQuestions = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $value -Name 'pending_questions')
            for ($i = 0; $i -lt $pendingQuestions.Count; $i++) {
                Test-TaskInputQuestionObject -Question $pendingQuestions[$i] -Path "$path.pending_questions[$i]" -Errors $errors
            }
        }
    }

    return $errors.ToArray()
}

function Assert-TaskInputQuestionPayload {
    param(
        [Parameter(Mandatory)] $TaskContent
    )

    $errors = @(Test-TaskInputQuestionPayload -TaskContent $TaskContent)
    if ($errors.Count -gt 0) {
        throw "Invalid task input question payload: $($errors -join '; ')"
    }
}

function Ensure-TaskInputPendingQuestionIds {
    <#
    .SYNOPSIS
    Ensures every pending question in a task batch has a stable per-batch id.

    .DESCRIPTION
    Agents occasionally write pending_questions without ids. The UI submits
    one answer at a time and the transition removes the answered question by
    id, so a batch of null ids collapses into "all questions answered". Assign
    deterministic ids in order and repair duplicates before any surface renders
    or mutates the batch.
    #>
    param(
        [Parameter(Mandatory)] $TaskContent
    )

    $runnerInfo = Get-TaskInputRunnerBag -TaskContent $TaskContent
    $runner = $runnerInfo.Bag
    $pendingQuestions = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $runner -Name 'pending_questions')
    if ($pendingQuestions.Count -eq 0) {
        return @{ changed = $false; questions = @(); runner = $runner }
    }

    $changed = $false
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $pendingQuestions.Count; $i++) {
        $question = $pendingQuestions[$i]
        $id = [string](Get-TaskInputProp -Object $question -Name 'id')
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.Contains($id)) {
            $candidate = "q$($i + 1)"
            $suffix = 1
            while ($seen.Contains($candidate)) {
                $suffix++
                $candidate = "q$($i + 1)-$suffix"
            }
            Set-TaskInputProp -Object $question -Name 'id' -Value $candidate
            $id = $candidate
            $changed = $true
        }
        [void]$seen.Add($id)
    }

    if ($changed) {
        Set-TaskInputProp -Object $runner -Name 'pending_questions' -Value $pendingQuestions
    }

    return @{ changed = $changed; questions = $pendingQuestions; runner = $runner }
}

function Get-TaskInputRunnerBag {
    param([Parameter(Mandatory)] $TaskContent)

    $extensions = Get-TaskInputProp -Object $TaskContent -Name 'extensions'
    if ($extensions) {
        $runner = Get-TaskInputProp -Object $extensions -Name 'runner'
        if (-not $runner) {
            $runner = [pscustomobject]@{}
            Set-TaskInputProp -Object $extensions -Name 'runner' -Value $runner
        }
        return @{ Bag = $runner; UsesExtensions = $true }
    }

    return @{ Bag = $TaskContent; UsesExtensions = $false }
}

function Get-TaskInputTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Resolve-TaskInputAnswer {
    param(
        [Parameter(Mandatory)] $Question,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Answer
    )

    $resolvedAnswer = $Answer
    $answerType = 'custom'
    $answerKey = $null
    $matchingOption = $null

    $validKeys = @('A', 'B', 'C', 'D', 'E')
    if ($Answer -and $Answer.ToUpperInvariant() -in $validKeys) {
        $answerKey = $Answer.ToUpperInvariant()
        $answerType = 'option'
        $options = Get-TaskInputProp -Object $Question -Name 'options'
        $matchingOption = @($options | Where-Object { (Get-TaskInputProp -Object $_ -Name 'key') -eq $answerKey }) | Select-Object -First 1
        if ($matchingOption) {
            $resolvedAnswer = "$answerKey - $(Get-TaskInputProp -Object $matchingOption -Name 'label')"
        } else {
            $resolvedAnswer = $answerKey
        }
    }

    return @{
        answer = $resolvedAnswer
        answer_type = $answerType
        answer_key = $answerKey
        answer_label = if ($matchingOption) { Get-TaskInputProp -Object $matchingOption -Name 'label' } else { $null }
    }
}

function Get-TaskInputProductDir {
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [string]$TaskId
    )

    if ($TaskId -and (Get-Command Get-TaskWorktreeInfo -ErrorAction SilentlyContinue)) {
        try {
            $worktreeInfo = Get-TaskWorktreeInfo -TaskId $TaskId -BotRoot $BotRoot
            $worktreePath = if ($worktreeInfo -and $worktreeInfo.PSObject.Properties['worktree_path']) { [string]$worktreeInfo.worktree_path } else { $null }
            if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
                $worktreeProductDir = Join-Path $worktreePath ".bot/workspace/product"
                if (Test-Path -LiteralPath $worktreeProductDir) {
                    return $worktreeProductDir
                }
            }
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message "Could not resolve task worktree product dir" -Exception $_
            }
        }
    }

    return (Join-Path (Join-Path $BotRoot "workspace") "product")
}

function Write-TaskInputInterviewAnswer {
    param(
        [string]$BotRoot,
        [string]$TaskId,
        [hashtable]$Entry
    )

    $productDir = Get-TaskInputProductDir -BotRoot $BotRoot -TaskId $TaskId
    if (-not (Test-Path -LiteralPath $productDir)) { return }

    $answersPath = Join-Path $productDir "interview-answers.json"
    $existing = @()
    if (Test-Path -LiteralPath $answersPath) {
        try {
            $existing = @((Get-Content -LiteralPath $answersPath -Raw | ConvertFrom-Json).answers)
        } catch {
            $existing = @()
        }
    }

    $existing = @($existing | Where-Object { $_.question_id -ne $Entry.question_id })
    $existing += [pscustomobject]$Entry
    @{ answers = $existing } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $answersPath -Encoding UTF8NoBOM
}

function Get-TaskInputTargetPath {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$NewStatus
    )

    $parentDir = Split-Path -Parent $TaskFile.FullName
    $parentLeaf = Split-Path -Leaf $parentDir
    $legacyStateDirs = @('todo', 'needs-input', 'in-progress', 'needs-review', 'done', 'skipped', 'cancelled', 'split')

    if ($legacyStateDirs -contains $parentLeaf) {
        $targetDir = Join-Path (Join-Path $BotRoot "workspace" "tasks") $NewStatus
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
        return Join-Path $targetDir $TaskFile.Name
    }

    return $TaskFile.FullName
}

function Complete-TaskInputTransition {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$NewStatus,
        [Parameter(Mandatory)] [string]$Now,
        [string]$Actor
    )

    Set-TaskInputProp -Object $TaskContent -Name 'status' -Value $NewStatus
    Set-TaskInputProp -Object $TaskContent -Name 'updated_at' -Value $Now
    if ($Actor) {
        Set-TaskInputProp -Object $TaskContent -Name 'updated_by' -Value $Actor
    }

    $terminal = @('done', 'failed', 'skipped', 'cancelled')
    if ($terminal -contains $NewStatus) {
        Set-TaskInputProp -Object $TaskContent -Name 'completed_at' -Value $Now
    } elseif (Get-TaskInputProp -Object $TaskContent -Name 'completed_at') {
        Set-TaskInputProp -Object $TaskContent -Name 'completed_at' -Value $null
    }

    $targetPath = Get-TaskInputTargetPath -TaskFile $TaskFile -BotRoot $BotRoot -NewStatus $NewStatus
    Move-TaskFileAtomic -SourcePath $TaskFile.FullName `
                        -TargetPath $targetPath `
                        -Content $TaskContent `
                        -Depth 20 `
                        -TaskId $TaskId `
                        -BotRoot $BotRoot
    return $targetPath
}

function Add-TaskInputResolvedQuestion {
    param(
        [Parameter(Mandatory)] $RunnerBag,
        [Parameter(Mandatory)] $Question,
        [Parameter(Mandatory)] [hashtable]$Resolved,
        [Parameter(Mandatory)] [string]$AnsweredAt,
        [Parameter(Mandatory)] [string]$AnsweredVia,
        [array]$Attachments = @(),
        # Type-specific fields surfaced by Resolve-NotificationAnswer when polling
        # answers from the Mothership. Comment is approval-only, RankedItems is
        # priorityRanking-only, ReviewedAttachmentIds is approval-with-attachments.
        # Each is written onto the resolved entry only when populated.
        [string]$Comment,
        [array]$RankedItems,
        [array]$ReviewedAttachmentIds
    )

    $entry = @{
        id = Get-TaskInputProp -Object $Question -Name 'id'
        question = Get-TaskInputProp -Object $Question -Name 'question'
        answer = $Resolved.answer
        answer_type = $Resolved.answer_type
        asked_at = Get-TaskInputProp -Object $Question -Name 'asked_at'
        answered_at = $AnsweredAt
        answered_via = $AnsweredVia
    }
    if ($Attachments -and @($Attachments).Count -gt 0) {
        $entry['attachments'] = $Attachments
    }
    if ($Comment) {
        $entry['comment'] = $Comment
    }
    if ($RankedItems -and @($RankedItems).Count -gt 0) {
        $entry['ranked_items'] = @($RankedItems)
    }
    if ($ReviewedAttachmentIds -and @($ReviewedAttachmentIds).Count -gt 0) {
        $entry['reviewed_attachment_ids'] = @($ReviewedAttachmentIds)
    }

    $existing = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $RunnerBag -Name 'questions_resolved')
    $existing += [pscustomobject]$entry
    Set-TaskInputProp -Object $RunnerBag -Name 'questions_resolved' -Value $existing
    return $entry
}

function Invoke-TaskQuestionAnswerTransition {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Answer,
        [Parameter(Mandatory)] [string]$BotRoot,
        [string]$QuestionId,
        [array]$Attachments = @(),
        [string]$AnsweredVia = 'ui',
        [string]$Actor,
        # Type-specific fields supplied by the notification poller (server -> outpost
        # direction only). Local UI submissions leave these unset; only the answer
        # string is captured for the local approve/reject path.
        [string]$Comment,
        [array]$RankedItems,
        [array]$ReviewedAttachmentIds
    )

    $taskId = [string](Get-TaskInputProp -Object $TaskContent -Name 'id')
    if (-not $taskId) { throw "Task has no id" }
    if ([string](Get-TaskInputProp -Object $TaskContent -Name 'status') -ne 'needs-input') {
        throw "Task with ID '$taskId' is not in needs-input status"
    }

    $normalization = Ensure-TaskInputPendingQuestionIds -TaskContent $TaskContent
    $runner = $normalization.runner
    $pendingQuestions = $normalization.questions
    $pendingQuestion = Get-TaskInputProp -Object $runner -Name 'pending_question'

    if ($pendingQuestions.Count -gt 0) {
        $targetQuestion = $null
        if ($QuestionId) {
            $targetQuestion = @($pendingQuestions | Where-Object { (Get-TaskInputProp -Object $_ -Name 'id') -eq $QuestionId }) | Select-Object -First 1
            if (-not $targetQuestion) { throw "Question with ID '$QuestionId' not found in pending_questions" }
        } else {
            $targetQuestion = $pendingQuestions[0]
        }

        $resolved = Resolve-TaskInputAnswer -Question $targetQuestion -Answer $Answer
        $now = Get-TaskInputTimestamp
        Add-TaskInputResolvedQuestion -RunnerBag $runner -Question $targetQuestion -Resolved $resolved -AnsweredAt $now -AnsweredVia $AnsweredVia -Attachments $Attachments -Comment $Comment -RankedItems $RankedItems -ReviewedAttachmentIds $ReviewedAttachmentIds | Out-Null
        Write-TaskInputInterviewAnswer -BotRoot $BotRoot -TaskId $taskId -Entry @{
            task_id = $taskId
            question_id = Get-TaskInputProp -Object $targetQuestion -Name 'id'
            question = Get-TaskInputProp -Object $targetQuestion -Name 'question'
            context = Get-TaskInputProp -Object $targetQuestion -Name 'context'
            answer_key = $resolved.answer_key
            answer_label = $resolved.answer_label
            answer = $resolved.answer
            answered_at = $now
        }

        $targetQuestionId = Get-TaskInputProp -Object $targetQuestion -Name 'id'
        $remaining = @($pendingQuestions | Where-Object { (Get-TaskInputProp -Object $_ -Name 'id') -ne $targetQuestionId })
        Set-TaskInputProp -Object $runner -Name 'pending_questions' -Value $remaining
        $notifications = Get-TaskInputProp -Object $runner -Name 'notifications'
        if (-not $notifications) { $notifications = Get-TaskInputProp -Object $TaskContent -Name 'notifications' }
        if ($notifications) {
            Remove-TaskInputProp -Object $notifications -Name (Get-TaskInputProp -Object $targetQuestion -Name 'id')
        }

        Set-TaskInputProp -Object $TaskContent -Name 'updated_at' -Value $now
        if ($Actor) { Set-TaskInputProp -Object $TaskContent -Name 'updated_by' -Value $Actor }

        if ($remaining.Count -gt 0) {
            Write-TaskFileAtomic -Path $TaskFile.FullName -Content $TaskContent -Depth 20 -TaskId $taskId -BotRoot $BotRoot
            return @{
                success = $true
                message = "Question answered - $($remaining.Count) question(s) still pending"
                task_id = $taskId
                task_name = Get-TaskInputProp -Object $TaskContent -Name 'name'
                old_status = 'needs-input'
                new_status = 'needs-input'
                question = Get-TaskInputProp -Object $targetQuestion -Name 'question'
                answer = $resolved.answer
                answer_type = $resolved.answer_type
                questions_resolved_count = (ConvertTo-TaskInputArray (Get-TaskInputProp -Object $runner -Name 'questions_resolved')).Count
                questions_remaining_count = $remaining.Count
                file_path = $TaskFile.FullName
            }
        }

        Set-TaskInputProp -Object $runner -Name 'all_questions_answered' -Value $true
        $newStatus = if ($resolved.answer -match '(?i)skip\s*task|skip\s*-|already\s*exist') { 'skipped' } else { 'todo' }
        if ($newStatus -eq 'skipped') {
            Set-TaskInputProp -Object $runner -Name 'skip_reason' -Value 'superseded'
            $skips = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $runner -Name 'skip_history')
            $skips += [pscustomobject]@{ skipped_at = $now; reason = "Skipped via question answer: $($resolved.answer)" }
            Set-TaskInputProp -Object $runner -Name 'skip_history' -Value $skips
        }
        $handoffDisposition = if ($newStatus -eq 'skipped') { 'superseded' } else { 'consumed' }
        Complete-DotbotTaskHandoffForAnswer `
            -TaskContent $TaskContent `
            -BotRoot $BotRoot `
            -QuestionId $targetQuestionId `
            -Answer $resolved.answer `
            -AnsweredAt $now `
            -Disposition $handoffDisposition | Out-Null
        $newPath = Complete-TaskInputTransition -TaskFile $TaskFile -TaskContent $TaskContent -BotRoot $BotRoot -TaskId $taskId -NewStatus $newStatus -Now $now -Actor $Actor

        return @{
            success = $true
            message = if ($newStatus -eq 'skipped') { "All questions answered - task skipped" } else { "All questions answered - task requeued" }
            task_id = $taskId
            task_name = Get-TaskInputProp -Object $TaskContent -Name 'name'
            old_status = 'needs-input'
            new_status = $newStatus
            question = Get-TaskInputProp -Object $targetQuestion -Name 'question'
            answer = $resolved.answer
            answer_type = $resolved.answer_type
            attachments_count = if ($Attachments) { @($Attachments).Count } else { 0 }
            questions_resolved_count = (ConvertTo-TaskInputArray (Get-TaskInputProp -Object $runner -Name 'questions_resolved')).Count
            questions_remaining_count = 0
            file_path = $newPath
        }
    }

    if (-not $pendingQuestion) {
        throw "Task has no pending question to answer"
    }

    $resolvedSingle = Resolve-TaskInputAnswer -Question $pendingQuestion -Answer $Answer
    $nowSingle = Get-TaskInputTimestamp
        Add-TaskInputResolvedQuestion -RunnerBag $runner -Question $pendingQuestion -Resolved $resolvedSingle -AnsweredAt $nowSingle -AnsweredVia $AnsweredVia -Attachments $Attachments -Comment $Comment -RankedItems $RankedItems -ReviewedAttachmentIds $ReviewedAttachmentIds | Out-Null
    Write-TaskInputInterviewAnswer -BotRoot $BotRoot -TaskId $taskId -Entry @{
            task_id = $taskId
            question_id = Get-TaskInputProp -Object $pendingQuestion -Name 'id'
            question = Get-TaskInputProp -Object $pendingQuestion -Name 'question'
            context = Get-TaskInputProp -Object $pendingQuestion -Name 'context'
        answer_key = $resolvedSingle.answer_key
        answer_label = $resolvedSingle.answer_label
        answer = $resolvedSingle.answer
        answered_at = $nowSingle
    }

    Set-TaskInputProp -Object $runner -Name 'pending_question' -Value $null
    Remove-TaskInputProp -Object $runner -Name 'notification'
    Remove-TaskInputProp -Object $TaskContent -Name 'notification'

    $singleNewStatus = if ($resolvedSingle.answer -match '(?i)skip\s*task|skip\s*-|already\s*exist') { 'skipped' } else { 'todo' }
    if ($singleNewStatus -eq 'skipped') {
        Set-TaskInputProp -Object $runner -Name 'skip_reason' -Value 'superseded'
        $singleSkips = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $runner -Name 'skip_history')
        $singleSkips += [pscustomobject]@{ skipped_at = $nowSingle; reason = "Skipped via question answer: $($resolvedSingle.answer)" }
        Set-TaskInputProp -Object $runner -Name 'skip_history' -Value $singleSkips
    }
    $singleHandoffDisposition = if ($singleNewStatus -eq 'skipped') { 'superseded' } else { 'consumed' }
    Complete-DotbotTaskHandoffForAnswer `
        -TaskContent $TaskContent `
        -BotRoot $BotRoot `
        -QuestionId ([string](Get-TaskInputProp -Object $pendingQuestion -Name 'id')) `
        -Answer $resolvedSingle.answer `
        -AnsweredAt $nowSingle `
        -Disposition $singleHandoffDisposition | Out-Null
    $singlePath = Complete-TaskInputTransition -TaskFile $TaskFile -TaskContent $TaskContent -BotRoot $BotRoot -TaskId $taskId -NewStatus $singleNewStatus -Now $nowSingle -Actor $Actor

    return @{
        success = $true
        message = if ($singleNewStatus -eq 'skipped') { "Question answered - task skipped" } else { "Question answered - task requeued" }
        task_id = $taskId
        task_name = Get-TaskInputProp -Object $TaskContent -Name 'name'
        old_status = 'needs-input'
        new_status = $singleNewStatus
        question = Get-TaskInputProp -Object $pendingQuestion -Name 'question'
        answer = $resolvedSingle.answer
        answer_type = $resolvedSingle.answer_type
        attachments_count = if ($Attachments) { @($Attachments).Count } else { 0 }
        questions_resolved_count = (ConvertTo-TaskInputArray (Get-TaskInputProp -Object $runner -Name 'questions_resolved')).Count
        file_path = $singlePath
    }
}

function Invoke-TaskSplitDecisionTransition {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] $TaskContent,
        [Parameter(Mandatory)] [bool]$Approved,
        [Parameter(Mandatory)] [string]$BotRoot,
        [string]$AnsweredVia = 'ui',
        [string]$Actor
    )

    $taskId = [string](Get-TaskInputProp -Object $TaskContent -Name 'id')
    if (-not $taskId) { throw "Task has no id" }
    if ([string](Get-TaskInputProp -Object $TaskContent -Name 'status') -ne 'needs-input') {
        throw "Task with ID '$taskId' is not in needs-input status"
    }
    $runnerInfo = Get-TaskInputRunnerBag -TaskContent $TaskContent
    $runner = $runnerInfo.Bag
    $splitProposal = Get-TaskInputProp -Object $runner -Name 'split_proposal'
    if (-not $splitProposal) { $splitProposal = Get-TaskInputProp -Object $TaskContent -Name 'split_proposal' }
    if (-not $splitProposal) { throw "Task has no split proposal to approve/reject" }

    $now = Get-TaskInputTimestamp
    $decisionStatus = if ($Approved) { 'approved' } else { 'rejected' }
    Set-TaskInputProp -Object $splitProposal -Name 'status' -Value $decisionStatus
    Set-TaskInputProp -Object $splitProposal -Name 'answered_via' -Value $AnsweredVia
    $decisionTimestampField = if ($Approved) { 'approved_at' } else { 'rejected_at' }
    Set-TaskInputProp -Object $splitProposal -Name $decisionTimestampField -Value $now
    Remove-TaskInputProp -Object $runner -Name 'notification'
    Remove-TaskInputProp -Object $TaskContent -Name 'notification'

    if ($Approved) {
        $createdTasks = @()
        $subTasks = ConvertTo-TaskInputArray (Get-TaskInputProp -Object $splitProposal -Name 'sub_tasks')
        $parentProvenance = Get-TaskInputProp -Object $TaskContent -Name 'provenance'
        $parentExtensions = Get-TaskInputProp -Object $TaskContent -Name 'extensions'
        $parentWorkflow = Get-TaskInputProp -Object $parentProvenance -Name 'workflow'
        $parentRunId = Get-TaskInputProp -Object $parentProvenance -Name 'run_id'
        $parentDir = Split-Path -Parent $TaskFile.FullName

        foreach ($subTask in $subTasks) {
            $subName = [string](Get-TaskInputProp -Object $subTask -Name 'name')
            if ([string]::IsNullOrWhiteSpace($subName)) { continue }

            $parentDeps = @(Get-TaskInputProp -Object $TaskContent -Name 'dependencies' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $subDeps = @(Get-TaskInputProp -Object $subTask -Name 'dependencies' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $deps = if ($subDeps.Count -gt 0) { $subDeps } else { $parentDeps }

            $childProvenance = $null
            if ($parentRunId) {
                $childProvenance = @{
                    workflow = $parentWorkflow
                    run_id = $parentRunId
                    definition_name = $subName
                    expanded_by = "task:$taskId"
                }
            }

            $childExtensions = @{
                runner = @{
                    parent_task_id = $taskId
                    split_from = $taskId
                }
            }
            $parentWorkflowExt = $null
            if ($parentExtensions) {
                $parentWorkflowExt = Get-TaskInputProp -Object $parentExtensions -Name 'workflow'
            }
            if ($parentWorkflowExt) {
                $childExtensions['workflow'] = $parentWorkflowExt
            }

            $acceptanceCriteria = @(Get-TaskInputProp -Object $subTask -Name 'acceptance_criteria' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $outputs = @(Get-TaskInputProp -Object $subTask -Name 'outputs' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

            $childParams = @{
                Name = $subName
                Description = if (Get-TaskInputProp -Object $subTask -Name 'description') { [string](Get-TaskInputProp -Object $subTask -Name 'description') } else { "Sub-task of: $(Get-TaskInputProp -Object $TaskContent -Name 'name')" }
                Status = 'todo'
                Type = if (Get-TaskInputProp -Object $subTask -Name 'type') { [string](Get-TaskInputProp -Object $subTask -Name 'type') } else { 'prompt' }
                Category = if (Get-TaskInputProp -Object $subTask -Name 'category') { [string](Get-TaskInputProp -Object $subTask -Name 'category') } else { [string](Get-TaskInputProp -Object $TaskContent -Name 'category') }
                Priority = if ($null -ne (Get-TaskInputProp -Object $subTask -Name 'priority')) { Get-TaskInputProp -Object $subTask -Name 'priority' } else { Get-TaskInputProp -Object $TaskContent -Name 'priority' }
                Effort = if (Get-TaskInputProp -Object $subTask -Name 'effort') { [string](Get-TaskInputProp -Object $subTask -Name 'effort') } else { [string](Get-TaskInputProp -Object $TaskContent -Name 'effort') }
                Extensions = $childExtensions
                UpdatedBy = if ($Actor) { $Actor } else { "task-input" }
            }
            if ($deps.Count -gt 0) { $childParams['Dependencies'] = [string[]]$deps }
            if ($acceptanceCriteria.Count -gt 0) { $childParams['AcceptanceCriteria'] = [string[]]$acceptanceCriteria }
            if ($outputs.Count -gt 0) { $childParams['Outputs'] = [string[]]$outputs }
            if ($childProvenance) { $childParams['Provenance'] = $childProvenance }

            $childTask = New-TaskInstance @childParams

            if ($parentRunId) {
                $childPath = Join-Path $parentDir "$($childTask.id).json"
            } else {
                $layout = Get-StandaloneTaskLayout -BotRoot $BotRoot -TaskId $childTask.id -TaskName $childTask.name -CreatedAt $childTask.created_at
                $childPath = $layout.file_path
            }

            Write-TaskFileAtomic -Path $childPath -Content $childTask -Depth 20 -TaskId $childTask.id -BotRoot $BotRoot
            $createdTasks += [pscustomobject]@{
                id = $childTask.id
                name = $childTask.name
                file_path = $childPath
            }
        }

        $childTaskIds = @($createdTasks | ForEach-Object { $_.id })
        Set-TaskInputProp -Object $runner -Name 'skip_reason' -Value 'superseded'
        Set-TaskInputProp -Object $runner -Name 'split_reason' -Value (Get-TaskInputProp -Object $splitProposal -Name 'reason')
        Set-TaskInputProp -Object $runner -Name 'child_tasks' -Value $childTaskIds
        $newPath = Complete-TaskInputTransition -TaskFile $TaskFile -TaskContent $TaskContent -BotRoot $BotRoot -TaskId $taskId -NewStatus 'skipped' -Now $now -Actor $Actor
        return @{
            success = $true
            message = "Split proposal approved - created $($childTaskIds.Count) sub-task(s)"
            task_id = $taskId
            task_name = Get-TaskInputProp -Object $TaskContent -Name 'name'
            old_status = 'needs-input'
            new_status = 'skipped'
            approved = $true
            child_tasks = $childTaskIds
            created_tasks = $createdTasks
            sub_tasks_created = $childTaskIds.Count
            file_path = $newPath
        }
    }

    $rejectPath = Complete-TaskInputTransition -TaskFile $TaskFile -TaskContent $TaskContent -BotRoot $BotRoot -TaskId $taskId -NewStatus 'todo' -Now $now -Actor $Actor
    return @{
        success = $true
        message = "Split proposal rejected - task requeued"
        task_id = $taskId
        task_name = Get-TaskInputProp -Object $TaskContent -Name 'name'
        old_status = 'needs-input'
        new_status = 'todo'
        approved = $false
        file_path = $rejectPath
    }
}

Export-ModuleMember -Function @(
    'Assert-TaskInputQuestionPayload',
    'Assert-TaskInputQuestionsData',
    'Ensure-TaskInputPendingQuestionIds',
    'Invoke-TaskQuestionAnswerTransition',
    'Invoke-TaskSplitDecisionTransition',
    'Test-TaskInputQuestionPayload',
    'Test-TaskInputQuestionsData'
)
