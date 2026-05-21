<#
.SYNOPSIS
    Prompt-based process types: planning, commit, task-creation.
.DESCRIPTION
    Simple single-prompt process types that load a recipe template,
    optionally append a custom prompt, and stream to the provider.
    Extracted from launch-process.ps1 as part of v4 Phase 03 (#92).
#>

param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"


$Type = $Context.Type
$botRoot = $Context.BotRoot
$procId = $Context.ProcId
$processData = $Context.ProcessData
$claudeModelName = $Context.ModelName
$claudeSessionId = $Context.SessionId
$Prompt = $Context.Prompt
$Description = $Context.Description
$ShowDebug = $Context.ShowDebug
$ShowVerbose = $Context.ShowVerbose
$permissionMode = $Context.PermissionMode

# Determine workflow template
$workflowFile = switch ($Type) {
    'planning'      { Join-Path $botRoot "recipes\prompts\03-plan-roadmap.md" }
    'commit'        { Join-Path $botRoot "recipes\prompts\90-commit-and-push.md" }
    'task-creation' { Join-Path $botRoot "recipes\prompts\91-new-tasks.md" }
}

($processData.PSObject.Properties['workflow'] ? $processData.workflow : $null) | Out-Null
$processData.workflow = switch ($Type) {
    'planning'      { "03-plan-roadmap.md" }
    'commit'        { "90-commit-and-push.md" }
    'task-creation' { "91-new-tasks.md" }
}

# Build prompt
$systemPrompt = ""
if (Test-Path $workflowFile) {
    $systemPrompt = Get-Content $workflowFile -Raw
}

# For prompt-based types, append the custom prompt
if ($Prompt) {
    $fullPrompt = @"
$systemPrompt

## Additional Context

$Prompt
"@
} else {
    $fullPrompt = $systemPrompt
}

if (-not $Description) {
    $Description = switch ($Type) {
        'planning'      { "Plan roadmap" }
        'commit'        { "Commit and push changes" }
        'task-creation' { "Create new tasks" }
    }
}

($processData.PSObject.Properties['status'] ? $processData.status : $null) | Out-Null
($processData.PSObject.Properties['description'] ? $processData.description : $null) | Out-Null
($processData.PSObject.Properties['heartbeat_status'] ? $processData.heartbeat_status : $null) | Out-Null
$processData.status = 'running'
$processData.description = $Description
$processData.heartbeat_status = $Description
Write-ProcessFile -Id $procId -Data $processData
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "$Description started"

try {
    $streamArgs = @{
        Prompt = $fullPrompt
        Model = $claudeModelName
        SessionId = $claudeSessionId
        PersistSession = $false
    }
    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }
    if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }

    Invoke-ProviderStream @streamArgs

    ($processData.PSObject.Properties['completed_at'] ? $processData.completed_at : $null) | Out-Null
    $processData.status = 'completed'
    $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
    $processData.heartbeat_status = "Completed: $Description"
} catch {
    ($processData.PSObject.Properties['failed_at'] ? $processData.failed_at : $null) | Out-Null
    ($processData.PSObject.Properties['error'] ? $processData.error : $null) | Out-Null
    $processData.status = 'failed'
    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
    $processData.error = $_.Exception.Message
    $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
    Write-Status "Process failed: $($_.Exception.Message)" -Type Error
}

Write-ProcessFile -Id $procId -Data $processData
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status))"
