# Import session tracking module
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

function Invoke-TaskMarkNeedsInput {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']
    $question = $Arguments['question']
    $splitProposal = $Arguments['split_proposal']
    
    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    if (-not $question -and -not $splitProposal) {
        throw "Either a question or split_proposal is required"
    }
    
    if ($question -and $splitProposal) {
        throw "Cannot provide both question and split_proposal - use one at a time"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $analysingDir = Join-Path $tasksBaseDir "analysing"
    $needsInputDir = Join-Path $tasksBaseDir "needs-input"
    
    # Find the task file in analysing
    $taskFile = $null
    if (Test-Path $analysingDir) {
        $files = Get-ChildItem -Path $analysingDir -Filter "*.json" -File
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
        throw "Task with ID '$taskId' not found in analysing status"
    }
    
    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
    
    # Update task properties
    $taskContent.status = 'needs-input'
    $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Close current Claude session (marks session as ended but preserves session_id for resumption)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase 'analysis'
    }

    # Initialize questions_resolved array if it doesn't exist
    if (-not $taskContent.PSObject.Properties['questions_resolved']) {
        $taskContent | Add-Member -NotePropertyName 'questions_resolved' -NotePropertyValue @() -Force
    }
    
    # Store the pending question or split proposal
    if ($question) {
        # Generate question ID
        $questionId = "q$($taskContent.questions_resolved.Count + 1)"
        
        $pendingQuestion = @{
            id = $questionId
            question = $question.question
            context = $question.context
            options = $question.options
            recommendation = if ($question.recommendation) { $question.recommendation } else { "A" }
            asked_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        
        if (-not $taskContent.PSObject.Properties['pending_question']) {
            $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
        }
        $taskContent.pending_question = $pendingQuestion
        
        # Clear any existing split proposal
        if ($taskContent.PSObject.Properties['split_proposal']) {
            $taskContent.split_proposal = $null
        }
    }
    elseif ($splitProposal) {
        $proposal = @{
            reason = $splitProposal.reason
            sub_tasks = $splitProposal.sub_tasks
            proposed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        
        if (-not $taskContent.PSObject.Properties['split_proposal']) {
            $taskContent | Add-Member -NotePropertyName 'split_proposal' -NotePropertyValue $null -Force
        }
        $taskContent.split_proposal = $proposal
        
        # Clear any existing pending question
        if ($taskContent.PSObject.Properties['pending_question']) {
            $taskContent.pending_question = $null
        }
    }
    
    # Ensure needs-input directory exists
    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }
    
    # Move file to needs-input directory
    $newFilePath = Join-Path $needsInputDir $taskFile.Name
    
    # Save updated task to new location
    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
    Remove-Item -Path $taskFile.FullName -Force

    # --- External notification (opt-in) ---
    try {
        $notifModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\NotificationClient.psm1"
        if (Test-Path $notifModule) {
            Import-Module $notifModule -Force
            $settings = Get-NotificationSettings
            if ($settings.enabled -and $question) {
                $sendResult = Send-TaskNotification -TaskContent $taskContent -PendingQuestion $taskContent.pending_question
                if ($sendResult.success) {
                    $taskContent | Add-Member -NotePropertyName 'notification' -NotePropertyValue @{
                        question_id = $sendResult.question_id
                        instance_id = $sendResult.instance_id
                        channel     = $sendResult.channel
                        project_id  = $sendResult.project_id
                        sent_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    } -Force
                    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
                }
            }
        }
    } catch {
        # Never block the core flow - notification failure is non-fatal
    }

    # Build result
    $result = @{
        success = $true
        message = if ($question) { "Task paused for human input - question pending" } else { "Task paused for human input - split proposal pending" }
        task_id = $taskId
        task_name = $taskContent.name
        old_status = 'analysing'
        new_status = 'needs-input'
        file_path = $newFilePath
    }
    
    if ($question) {
        $result['pending_question'] = $taskContent.pending_question
    }
    elseif ($splitProposal) {
        $result['split_proposal'] = $taskContent.split_proposal
    }
    
    return $result
}
