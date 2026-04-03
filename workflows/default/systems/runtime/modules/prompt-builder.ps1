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
        $applicableStandards = "No specific standards listed for this task - use global standards from .bot/recipes/standards/global/"
    }
    $prompt = $prompt -replace '\{\{APPLICABLE_STANDARDS\}\}', $applicableStandards

    # Format and replace applicable agents
    $applicableAgents = ""
    if ($Task.applicable_agents -and $Task.applicable_agents.Count -gt 0) {
        $applicableAgents = ($Task.applicable_agents | ForEach-Object { "- $_" }) -join "`n"
    } else {
        $applicableAgents = "Use .bot/recipes/agents/implementer/AGENT.md as your default persona"
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

    # Add steering protocol include
    $steeringProtocolPath = Join-Path $PSScriptRoot "..\..\prompts\workflows\92-steering-protocol.include.md"
    $steeringProtocol = ""
    if (Test-Path $steeringProtocolPath) {
        $steeringProtocol = Get-Content $steeringProtocolPath -Raw -ErrorAction SilentlyContinue
    }
    $prompt = $prompt -replace '\{\{STEERING_PROTOCOL\}\}', $steeringProtocol

    return $prompt
}
