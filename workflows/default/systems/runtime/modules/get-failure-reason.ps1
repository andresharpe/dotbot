function Get-FailureReason {
    <#
    .SYNOPSIS
    Classifies the type of failure from Claude execution
    
    .PARAMETER ExitCode
    The exit code from the Claude process
    
    .PARAMETER Stdout
    Standard output from Claude
    
    .PARAMETER Stderr
    Standard error output from Claude
    
    .PARAMETER TimedOut
    Whether the process timed out
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        
        [Parameter(Mandatory = $false)]
        [string]$Stdout = "",
        
        [Parameter(Mandatory = $false)]
        [string]$Stderr = "",
        
        [Parameter(Mandatory = $false)]
        [bool]$TimedOut = $false
    )
    
    # Timeout takes precedence
    if ($TimedOut) {
        return @{
            type = "Timeout"
            description = "Claude session exceeded timeout limit"
            recoverable = $true
            suggested_action = "Retry with same task"
        }
    }
    
    # Check for auth/rate limit errors (from AutoCoder auth.py patterns)
    $authPatterns = @(
        "rate limit",
        "too many requests",
        "quota exceeded",
        "authentication failed",
        "invalid api key",
        "not authenticated",
        "429",
        "unauthorized"
    )
    
    $combinedOutput = "$Stdout $Stderr"
    foreach ($pattern in $authPatterns) {
        if ($combinedOutput -match $pattern) {
            return @{
                type = "AuthLimit"
                description = "Authentication or rate limit error detected"
                recoverable = $true
                suggested_action = "Switch auth method or wait for rate limit reset"
            }
        }
    }
    
    # Check for verification failures
    if ($combinedOutput -match "verification failed" -or 
        $combinedOutput -match "test.*failed" -or
        $combinedOutput -match "verification_passed.*false") {
        return @{
            type = "VerificationFailed"
            description = "Task verification scripts failed"
            recoverable = $true
            suggested_action = "Review verification output and retry"
        }
    }
    
    # Check for code errors
    if ($combinedOutput -match "syntax error" -or 
        $combinedOutput -match "compilation failed" -or
        $combinedOutput -match "parse error") {
        return @{
            type = "CodeError"
            description = "Code syntax or compilation error"
            recoverable = $true
            suggested_action = "Review code and retry"
        }
    }
    
    # Check for task not found or invalid task
    if ($combinedOutput -match "task.*not found" -or 
        $combinedOutput -match "invalid task") {
        return @{
            type = "TaskError"
            description = "Task not found or invalid"
            recoverable = $false
            suggested_action = "Skip this task"
        }
    }
    
    # Check if Claude ran out of iterations
    if ($combinedOutput -match "max iterations reached" -or
        $combinedOutput -match "iteration limit") {
        return @{
            type = "MaxIterations"
            description = "Go Mode reached maximum iterations without completion"
            recoverable = $true
            suggested_action = "Retry with increased max iterations or review task complexity"
        }
    }
    
    # Default to crash for any other non-zero exit code
    return @{
        type = "Crash"
        description = "Unexpected failure or crash (exit code: $ExitCode)"
        recoverable = $true
        suggested_action = "Review output and retry"
    }
}
