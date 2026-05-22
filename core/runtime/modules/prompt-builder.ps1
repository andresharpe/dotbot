<#
.SYNOPSIS
Prompt building utilities for task execution

.DESCRIPTION
Provides functions for building prompts from templates with variable substitution
#>
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
        [string]$InstanceId = "",

        [Parameter(Mandatory = $false)]
        [string]$WorkflowLaunchPrompt = ""
    )

    # Inside-function so dot-sourcing this file does not leak strict mode.
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = "Stop"

    # Start with template
    $prompt = $PromptTemplate

    # Replace basic task info
    $taskId = if ($Task.PSObject.Properties['id'] ? $Task.id : $null) { "$($Task.id)" } else { "" }
    $taskIdShort = if ($taskId.Length -gt 8) { $taskId.Substring(0, 8) } else { $taskId }

    $instanceIdShort = ""
    if ($InstanceId) {
        $guidMatch = [regex]::Match($InstanceId, '^[0-9a-fA-F]{8}')
        if ($guidMatch.Success) {
            $instanceIdShort = $guidMatch.Value.ToLowerInvariant()
        }
    }

    $prompt = $prompt.Replace('{{SESSION_ID}}', $SessionId)
    $prompt = $prompt.Replace('{{TASK_ID}}', $taskId)
    $prompt = $prompt.Replace('{{TASK_ID_SHORT}}', $taskIdShort)
    $prompt = $prompt.Replace('{{TASK_NAME}}', $Task.name)
    $prompt = $prompt.Replace('{{TASK_CATEGORY}}', ($Task.PSObject.Properties['category'] ? [string]$Task.category : ''))
    $prompt = $prompt.Replace('{{TASK_PRIORITY}}', "$($Task.PSObject.Properties['priority'] ? $Task.priority : $null)")
    $prompt = $prompt.Replace('{{TASK_DESCRIPTION}}', $Task.description)
    $prompt = $prompt.Replace('{{PRODUCT_MISSION}}', $ProductMission)
    $prompt = $prompt.Replace('{{ENTITY_MODEL}}', $EntityModel)
    $prompt = $prompt.Replace('{{INSTANCE_ID}}', $InstanceId)
    $prompt = $prompt.Replace('{{INSTANCE_ID_SHORT}}', $instanceIdShort)
    # Format and replace applicable standards
    $applicableStandards = ""
    if (($Task.PSObject.Properties['applicable_standards'] ? $Task.applicable_standards : $null) -and $Task.applicable_standards.Count -gt 0) {
        $applicableStandards = ($Task.applicable_standards | ForEach-Object { "- $_" }) -join "`n"
    } else {
        # Neutral fallback. The previous wording pushed agents toward
        # `.bot/recipes/standards/global/`, which is optional and absent in
        # most workflows; the analysis prompt already tells the agent not to
        # probe that directory.
        $applicableStandards = "No specific standards listed for this task — infer conventions from the codebase."
    }
    $prompt = $prompt.Replace('{{APPLICABLE_STANDARDS}}', $applicableStandards)

    # Format and replace applicable agents
    $applicableAgents = ""
    if (($Task.PSObject.Properties['applicable_agents'] ? $Task.applicable_agents : $null) -and $Task.applicable_agents.Count -gt 0) {
        $applicableAgents = ($Task.applicable_agents | ForEach-Object { "- $_" }) -join "`n"
    } else {
        $applicableAgents = "Use .bot/core/agents/implementer/AGENT.md as your default persona"
    }
    $prompt = $prompt.Replace('{{APPLICABLE_AGENTS}}', $applicableAgents)

    # Format and replace applicable skills
    $applicableSkills = ""
    if (($Task.PSObject.Properties['applicable_skills'] ? $Task.applicable_skills : $null) -and $Task.applicable_skills.Count -gt 0) {
        $applicableSkills = ($Task.applicable_skills | ForEach-Object { "- $_" }) -join "`n"
    } else {
        $applicableSkills = "No specific skills listed — use judgement based on task category"
    }
    $prompt = $prompt.Replace('{{APPLICABLE_SKILLS}}', $applicableSkills)

    # Format and replace acceptance criteria
    $acceptanceCriteria = if ($Task.PSObject.Properties['acceptance_criteria'] ? $Task.acceptance_criteria : $null) {
        ($Task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "No specific acceptance criteria defined."
    }
    $prompt = $prompt.Replace('{{ACCEPTANCE_CRITERIA}}', $acceptanceCriteria)

    # Format and replace steps
    $steps = if ($Task.PSObject.Properties['steps'] ? $Task.steps : $null) {
        ($Task.steps | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "No specific steps defined."
    }
    $prompt = $prompt.Replace('{{TASK_STEPS}}', $steps)

    # Replace standards list
    $prompt = $prompt.Replace('{{STANDARDS_LIST}}', $StandardsList)

    # Format needs_review flag
    $needsReviewValue = if ("$($Task.PSObject.Properties['needs_review'] ? $Task.needs_review : $null)" -eq 'true') { 'true' } else { 'false' }
    $prompt = $prompt.Replace('{{NEEDS_REVIEW}}', $needsReviewValue)

    # Format reviewer feedback history
    $reviewerFeedbackText = ""
    if (($Task.PSObject.Properties['reviewer_feedback'] ? $Task.reviewer_feedback : $null) -and @($Task.reviewer_feedback).Count -gt 0) {
        $feedbackList = @($Task.reviewer_feedback)
        $reviewerFeedbackText = "## Prior Reviewer Feedback`n`nThis task has been rejected $($feedbackList.Count) time(s). You MUST address ALL of the following feedback in your implementation:`n`n"
        $i = 1
        foreach ($fb in $feedbackList) {
            $reviewerFeedbackText += "### Rejection #$i ($($fb.timestamp))`n"
            if ($fb.comment) { $reviewerFeedbackText += "**Comment:** $($fb.comment)`n" }
            if ($fb.what_was_wrong) { $reviewerFeedbackText += "**What was wrong:** $($fb.what_was_wrong)`n" }
            $reviewerFeedbackText += "`n"
            $i++
        }
    }
    $prompt = $prompt.Replace('{{REVIEWER_FEEDBACK}}', $reviewerFeedbackText)

    $prompt = $prompt.Replace('{{WORKFLOW_LAUNCH_PROMPT}}', $WorkflowLaunchPrompt)

    # Format and replace questions resolved (user decisions from analysis Q&A)
    $questionsResolved = ""
    $taskQR = if ($Task.PSObject.Properties['questions_resolved']) { $Task.questions_resolved } else { $null }
    if ($taskQR -and @($taskQR).Count -gt 0) {
        $questionsResolved = "The following decisions were made by the user during analysis. You **MUST** honour them — do not contradict or override these answers.`n`n"
        foreach ($qa in $taskQR) {
            $questionsResolved += "**Q:** $($qa.question)`n"
            $questionsResolved += "**A:** $($qa.answer)`n`n"
        }
    }
    $prompt = $prompt.Replace('{{QUESTIONS_RESOLVED}}', $questionsResolved)

    # Add steering protocol include
    $steeringProtocolPath = Join-Path $PSScriptRoot "../../prompts/92-steering-protocol.include.md"
    $steeringProtocol = ""
    if (Test-Path $steeringProtocolPath) {
        $steeringProtocol = Get-Content $steeringProtocolPath -Raw -ErrorAction SilentlyContinue
    }
    $prompt = $prompt.Replace('{{STEERING_PROTOCOL}}', $steeringProtocol)

    return $prompt
}
