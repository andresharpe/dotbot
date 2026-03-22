function New-ProblemLog {
    <#
    .SYNOPSIS
    Create a problem log file for a task that encountered issues during implementation
    
    .PARAMETER TaskId
    The task ID this problem is associated with
    
    .PARAMETER Problems
    Array of problem objects, each containing:
    - id: Unique identifier
    - phase: When it occurred (implementation/verification/testing/pre-commit)
    - problem_type: Category (missing_dependency/configuration_error/etc)
    - severity: How blocking (blocking/high/medium/low)
    - description: What happened
    - context: Object with file_path, line_number, command_executed, error_message
    - root_cause: Why did this happen?
    - solution: Object with action_taken, commands_executed, files_modified, verification
    - prevention: Object with improvement_category, suggestion, impacted_files, priority
    
    .PARAMETER SessionId
    The session ID from autonomous session
    
    .PARAMETER AgentPersona
    Path to the agent persona file used
    
    .PARAMETER ApplicableStandards
    Array of applicable standards from task
    
    .PARAMETER TaskCompleted
    Whether the task was successfully completed despite problems
    
    .EXAMPLE
    New-ProblemLog -TaskId "abc-123" -Problems $problemsArray -SessionId "session-xyz" -TaskCompleted $true
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,
        
        [Parameter(Mandatory = $true)]
        [object[]]$Problems,
        
        [Parameter(Mandatory = $true)]
        [string]$SessionId,
        
        [Parameter(Mandatory = $false)]
        [string]$AgentPersona = ".bot/agents/autonomous-coder.md",
        
        [Parameter(Mandatory = $false)]
        [string[]]$ApplicableStandards = @(),
        
        [Parameter(Mandatory = $false)]
        [bool]$TaskCompleted = $false
    )
    
    # Create directory if needed
    $pendingDir = Join-Path $PSScriptRoot "..\..\future-ideas\pending"
    if (-not (Test-Path $pendingDir)) {
        New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
    }
    
    # Generate filename with task ID and timestamp
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH-mm-ssZ"
    $filename = Join-Path $pendingDir "${TaskId}_${timestamp}.json"
    
    # Calculate metrics
    $totalProblems = $Problems.Count
    $blockingProblems = ($Problems | Where-Object { $_.severity -eq "blocking" }).Count
    $totalResolutionTime = 0
    foreach ($problem in $Problems) {
        if ($problem.discovered_at -and $problem.resolved_at) {
            $discovered = [datetime]::Parse($problem.discovered_at)
            $resolved = [datetime]::Parse($problem.resolved_at)
            $totalResolutionTime += ($resolved - $discovered).TotalSeconds
        }
    }
    
    # Build problem log object
    $logObject = @{
        log_version = "1.0"
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        task = @{
            id = $TaskId
        }
        problems = $Problems
        session_info = @{
            session_id = $SessionId
            agent_persona = $AgentPersona
            applicable_standards = $ApplicableStandards
        }
        metadata = @{
            total_problems = $totalProblems
            blocking_problems = $blockingProblems
            total_resolution_time_seconds = $totalResolutionTime
            task_completed = $TaskCompleted
            notes = "Autonomous task implementation - problems encountered and resolved"
        }
    }
    
    # Write to file
    $logObject | ConvertTo-Json -Depth 10 | Set-Content -Path $filename -Encoding UTF8
    
    # Import theme if available
    $themeModulePath = Join-Path $PSScriptRoot "DotBotTheme.psm1"
    if (Test-Path $themeModulePath) {
        Import-Module $themeModulePath -Force
        $t = Get-DotBotTheme
        Write-Host "$($t.Green)✓$($t.Reset) Problem log created: $($t.Cyan)$filename$($t.Reset)"
    } else {
        Write-Host "Problem log created: $filename" -ForegroundColor Green
    }
    return $filename
}
