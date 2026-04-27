# Persist an answered question to /workspace/product/interview-answers.json
# Only writes if workspace/product/ exists (i.e. discovery workflow projects)
function Write-InterviewAnswer {
    param(
        [string]$BotRoot,
        [hashtable]$Entry   # { question_id, question, answer_key, answer_label, answer, context, answered_at }
    )
    $productDir = Join-Path $BotRoot "workspace\product"
    if (-not (Test-Path $productDir)) { return }

    $answersPath = Join-Path $productDir "interview-answers.json"
    $existing = @()
    if (Test-Path $answersPath) {
        try { $existing = @((Get-Content $answersPath -Raw | ConvertFrom-Json).answers) } catch {}
    }

    # Upsert by question_id
    $existing = @($existing | Where-Object { $_.question_id -ne $Entry.question_id })
    $existing += [PSCustomObject]$Entry

    @{ answers = $existing } | ConvertTo-Json -Depth 10 | Set-Content $answersPath -Encoding UTF8NoBOM
}

function Invoke-TaskAnswerQuestion {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']
    $answer = $Arguments['answer']
    $attachments = $Arguments['attachments']
    $questionId = $Arguments['question_id']  # Optional: which question to answer (for pending_questions batch)

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }

    if (-not $answer) {
        throw "Answer is required"
    }

    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $needsInputDir = Join-Path $tasksBaseDir "needs-input"
    $analysingDir = Join-Path $tasksBaseDir "analysing"

    # Find the task file in needs-input
    $taskFile = $null
    if (Test-Path $needsInputDir) {
        $files = Get-ChildItem -Path $needsInputDir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    $taskFile = $file
                    break
                }
            } catch {
                # Continue searching
            }
        }
    }

    if (-not $taskFile) {
        throw "Task with ID '$taskId' not found in needs-input status"
    }

    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json

    # -----------------------------------------------------------------------
    # BATCH PATH: task has pending_questions array (new multi-question format)
    # -----------------------------------------------------------------------
    $hasPendingQuestionsArray = $taskContent.PSObject.Properties['pending_questions'] -and $taskContent.pending_questions -and @($taskContent.pending_questions).Count -gt 0

    if ($hasPendingQuestionsArray) {
        $pendingQuestions = @($taskContent.pending_questions)

        # Find the target question: by ID if provided, else the first one
        $targetQuestion = $null
        $targetIndex = -1
        if ($questionId) {
            for ($i = 0; $i -lt $pendingQuestions.Count; $i++) {
                if ($pendingQuestions[$i].id -eq $questionId) {
                    $targetQuestion = $pendingQuestions[$i]
                    $targetIndex = $i
                    break
                }
            }
            if (-not $targetQuestion) {
                throw "Question with ID '$questionId' not found in pending_questions"
            }
        } else {
            $targetQuestion = $pendingQuestions[0]
            $targetIndex = 0
        }

        # Resolve the answer
        $resolvedAnswer = $answer
        $answerType = "custom"
        $validKeys = @("A", "B", "C", "D", "E")
        if ($answer.ToUpperInvariant() -in $validKeys) {
            $answerKey = $answer.ToUpperInvariant()
            $answerType = "option"
            $matchingOption = $targetQuestion.options | Where-Object { $_.key -eq $answerKey } | Select-Object -First 1
            if ($matchingOption) {
                $resolvedAnswer = "$answerKey - $($matchingOption.label)"
            } else {
                $resolvedAnswer = $answerKey
            }
        }

        $answeredAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

        # Build resolved entry
        $resolvedEntry = @{
            id          = $targetQuestion.id
            question    = $targetQuestion.question
            answer      = $resolvedAnswer
            answer_type = $answerType
            asked_at    = $targetQuestion.asked_at
            answered_at = $answeredAt
        }
        if ($attachments -and $attachments.Count -gt 0) {
            $resolvedEntry['attachments'] = $attachments
        }

        # Persist to interview-answers.json (survives task resets)
        $interviewEntry = @{
            question_id  = $targetQuestion.id
            question     = $targetQuestion.question
            context      = $targetQuestion.context
            answer_key   = if ($answerType -eq 'option') { $answerKey } else { $null }
            answer_label = if ($answerType -eq 'option' -and $matchingOption) { $matchingOption.label } else { $null }
            answer       = $resolvedAnswer
            answered_at  = $answeredAt
        }
        Write-InterviewAnswer -BotRoot (Join-Path $global:DotbotProjectRoot '.bot') -Entry $interviewEntry

        # Add to questions_resolved
        if (-not $taskContent.PSObject.Properties['questions_resolved']) {
            $taskContent | Add-Member -NotePropertyName 'questions_resolved' -NotePropertyValue @() -Force
        }
        $existingResolved = @($taskContent.questions_resolved)
        $existingResolved += $resolvedEntry
        $taskContent.questions_resolved = $existingResolved

        # Remove this question from pending_questions
        $remaining = @()
        for ($i = 0; $i -lt $pendingQuestions.Count; $i++) {
            if ($i -ne $targetIndex) {
                $remaining += $pendingQuestions[$i]
            }
        }
        $taskContent.pending_questions = $remaining
        $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

        if ($remaining.Count -gt 0) {
            # More questions remain — stay in needs-input, just update the file
            $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $taskFile.FullName -Encoding UTF8
            return @{
                success                   = $true
                message                   = "Question answered - $($remaining.Count) question(s) still pending"
                task_id                   = $taskId
                task_name                 = $taskContent.name
                old_status                = 'needs-input'
                new_status                = 'needs-input'
                question                  = $targetQuestion.question
                answer                    = $resolvedAnswer
                answer_type               = $answerType
                questions_resolved_count  = $taskContent.questions_resolved.Count
                questions_remaining_count = $remaining.Count
                file_path                 = $taskFile.FullName
            }
        }

        # All questions answered — clear pending_questions and set flag so prompt skips to summary
        $taskContent.pending_questions = @()
        if ($taskContent.PSObject.Properties['all_questions_answered']) { $taskContent.all_questions_answered = $true }
        else { $taskContent | Add-Member -NotePropertyName 'all_questions_answered' -NotePropertyValue $true -Force }

        # Check skip signal
        $isSkipAnswer = $resolvedAnswer -match '(?i)skip\s*task|skip\s*-|already\s*exist'

        if ($isSkipAnswer) {
            $taskContent.status = 'skipped'
            if (-not $taskContent.PSObject.Properties['skip_history']) {
                $taskContent | Add-Member -NotePropertyName 'skip_history' -NotePropertyValue @() -Force
            }
            $existingSkips = @($taskContent.skip_history)
            $existingSkips += @{
                skipped_at = $taskContent.updated_at
                reason     = "Skipped via question answer: $resolvedAnswer"
            }
            $taskContent.skip_history = $existingSkips

            $skippedDir = Join-Path $tasksBaseDir "skipped"
            if (-not (Test-Path $skippedDir)) { New-Item -ItemType Directory -Force -Path $skippedDir | Out-Null }
            $newFilePath = Join-Path $skippedDir $taskFile.Name
            $newStatus = 'skipped'
            $message = "All questions answered - task skipped"
        } else {
            $hasCompletedAnalysis = $taskContent.PSObject.Properties['analysis_completed_at'] -and $taskContent.analysis_completed_at -and
                                    $taskContent.PSObject.Properties['analysis'] -and $taskContent.analysis
            if ($hasCompletedAnalysis) {
                $analysedDir = Join-Path $tasksBaseDir "analysed"
                if (-not (Test-Path $analysedDir)) { New-Item -ItemType Directory -Force -Path $analysedDir | Out-Null }
                $taskContent.status = 'analysed'
                $newFilePath = Join-Path $analysedDir $taskFile.Name
                $newStatus = 'analysed'
                $message = "All questions answered - task returned to execution (analysis already complete)"
            } else {
                $taskContent.status = 'analysing'
                if (-not (Test-Path $analysingDir)) { New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null }
                $newFilePath = Join-Path $analysingDir $taskFile.Name
                $newStatus = 'analysing'
                $message = "All questions answered - task returned to analysis"
            }
        }

        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
        Remove-Item -Path $taskFile.FullName -Force

        return @{
            success                  = $true
            message                  = $message
            task_id                  = $taskId
            task_name                = $taskContent.name
            old_status               = 'needs-input'
            new_status               = $newStatus
            question                 = $targetQuestion.question
            answer                   = $resolvedAnswer
            answer_type              = $answerType
            attachments_count        = if ($attachments) { @($attachments).Count } else { 0 }
            questions_resolved_count = $taskContent.questions_resolved.Count
            file_path                = $newFilePath
        }
    }

    # -----------------------------------------------------------------------
    # SINGULAR PATH: task has pending_question (legacy single-question format)
    # -----------------------------------------------------------------------

    # Verify there's a pending question
    if (-not $taskContent.pending_question) {
        throw "Task has no pending question to answer"
    }

    $pendingQuestion = $taskContent.pending_question

    # Resolve the answer
    $resolvedAnswer = $answer
    $answerType = "custom"

    # Check if answer is an option key
    $validKeys = @("A", "B", "C", "D", "E")
    if ($answer.ToUpperInvariant() -in $validKeys) {
        $answerKey = $answer.ToUpperInvariant()
        $answerType = "option"

        # Find the matching option
        $matchingOption = $pendingQuestion.options | Where-Object { $_.key -eq $answerKey } | Select-Object -First 1
        if ($matchingOption) {
            $resolvedAnswer = "$answerKey - $($matchingOption.label)"
        } else {
            $resolvedAnswer = $answerKey
        }
    }

    $answeredAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Create resolved question entry
    $resolvedEntry = @{
        id = $pendingQuestion.id
        question = $pendingQuestion.question
        answer = $resolvedAnswer
        answer_type = $answerType
        asked_at = $pendingQuestion.asked_at
        answered_at = $answeredAt
    }

    if ($attachments -and $attachments.Count -gt 0) {
        $resolvedEntry['attachments'] = $attachments
    }

    # Persist to interview-answers.json (survives task resets)
    $singularMatchingOption = if ($answerType -eq 'option') {
        $pendingQuestion.options | Where-Object { $_.key -eq $answerKey } | Select-Object -First 1
    } else { $null }
    Write-InterviewAnswer -BotRoot (Join-Path $global:DotbotProjectRoot '.bot') -Entry @{
        question_id  = $pendingQuestion.id
        question     = $pendingQuestion.question
        context      = $pendingQuestion.context
        answer_key   = if ($answerType -eq 'option') { $answerKey } else { $null }
        answer_label = if ($singularMatchingOption) { $singularMatchingOption.label } else { $null }
        answer       = $resolvedAnswer
        answered_at  = $answeredAt
    }

    # Add to questions_resolved array
    if (-not $taskContent.PSObject.Properties['questions_resolved']) {
        $taskContent | Add-Member -NotePropertyName 'questions_resolved' -NotePropertyValue @() -Force
    }

    # Convert to array if needed and append
    $existingResolved = @($taskContent.questions_resolved)
    $existingResolved += $resolvedEntry
    $taskContent.questions_resolved = $existingResolved

    # Clear pending question
    $taskContent.pending_question = $null
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Check if the answer indicates the task should be skipped
    $isSkipAnswer = $resolvedAnswer -match '(?i)skip\s*task|skip\s*-|already\s*exist'

    if ($isSkipAnswer) {
        # Transition directly to skipped
        $taskContent.status = 'skipped'

        # Add skip_history entry
        if (-not $taskContent.PSObject.Properties['skip_history']) {
            $taskContent | Add-Member -NotePropertyName 'skip_history' -NotePropertyValue @() -Force
        }
        $existingSkips = @($taskContent.skip_history)
        $existingSkips += @{
            skipped_at = $taskContent.updated_at
            reason = "Skipped via question answer: $resolvedAnswer"
        }
        $taskContent.skip_history = $existingSkips

        $skippedDir = Join-Path $tasksBaseDir "skipped"
        if (-not (Test-Path $skippedDir)) {
            New-Item -ItemType Directory -Force -Path $skippedDir | Out-Null
        }
        $newFilePath = Join-Path $skippedDir $taskFile.Name
        $newStatus = 'skipped'
        $message = "Question answered - task skipped"
    } else {
        # If the task already has a completed analysis, skip re-analysis and go straight to execution
        $hasCompletedAnalysis = $taskContent.PSObject.Properties['analysis_completed_at'] -and $taskContent.analysis_completed_at -and
                                $taskContent.PSObject.Properties['analysis'] -and $taskContent.analysis
        if ($hasCompletedAnalysis) {
            $analysedDir = Join-Path $tasksBaseDir "analysed"
            if (-not (Test-Path $analysedDir)) {
                New-Item -ItemType Directory -Force -Path $analysedDir | Out-Null
            }
            $taskContent.status = 'analysed'
            $newFilePath = Join-Path $analysedDir $taskFile.Name
            $newStatus = 'analysed'
            $message = "Question answered - task returned to execution (analysis already complete)"
        } else {
            # No prior analysis — send back to analysing so analysis runs first
            $taskContent.status = 'analysing'
            if (-not (Test-Path $analysingDir)) {
                New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null
            }
            $newFilePath = Join-Path $analysingDir $taskFile.Name
            $newStatus = 'analysing'
            $message = "Question answered - task returned to analysis"
        }
    }

    # Save updated task to new location
    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
    Remove-Item -Path $taskFile.FullName -Force

    # Return result
    return @{
        success = $true
        message = $message
        task_id = $taskId
        task_name = $taskContent.name
        old_status = 'needs-input'
        new_status = $newStatus
        question = $pendingQuestion.question
        answer = $resolvedAnswer
        answer_type = $answerType
        attachments_count = if ($attachments) { @($attachments).Count } else { 0 }
        questions_resolved_count = $taskContent.questions_resolved.Count
        file_path = $newFilePath
    }
}
