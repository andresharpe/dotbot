function Invoke-TaskAnswerQuestion {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $taskId = $Arguments['task_id']
    $answer = $Arguments['answer']
    
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
    if ($answer.ToUpper() -in $validKeys) {
        $answerKey = $answer.ToUpper()
        $answerType = "option"
        
        # Find the matching option
        $matchingOption = $pendingQuestion.options | Where-Object { $_.key -eq $answerKey } | Select-Object -First 1
        if ($matchingOption) {
            $resolvedAnswer = "$answerKey - $($matchingOption.label)"
        } else {
            $resolvedAnswer = $answerKey
        }
    }
    
    # Create resolved question entry
    $resolvedEntry = @{
        id = $pendingQuestion.id
        question = $pendingQuestion.question
        answer = $resolvedAnswer
        answer_type = $answerType
        asked_at = $pendingQuestion.asked_at
        answered_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
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
        # Move back to analysing for continued analysis
        $taskContent.status = 'analysing'
        
        if (-not (Test-Path $analysingDir)) {
            New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null
        }
        $newFilePath = Join-Path $analysingDir $taskFile.Name
        $newStatus = 'analysing'
        $message = "Question answered - task returned to analysis"
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
        questions_resolved_count = $taskContent.questions_resolved.Count
        file_path = $newFilePath
    }
}
