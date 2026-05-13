<#
.SYNOPSIS
Failure classifier for harness invocations.

.DESCRIPTION
Maps an exit code + stdout/stderr from any harness CLI to a structured failure
category (Timeout, AuthError, VerificationFailed, CodeError, TaskError,
MaxIterations, Crash). Adapter-agnostic — only inspects exit code, output text,
and a TimedOut flag.

Consumed by Invoke-WorkflowProcess after a non-zero exit to decide whether the
task is retryable.
#>

function Get-FailureReason {
    [CmdletBinding()]
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

    if ($TimedOut) {
        return @{
            type = "Timeout"
            description = "Harness session exceeded timeout limit"
            recoverable = $true
            suggested_action = "Retry with same task"
        }
    }

    $authFailures = @(
        "authentication failed",
        "invalid api key",
        "not authenticated",
        "unauthorized"
    )

    $combinedOutput = "$Stdout $Stderr"
    foreach ($failureText in $authFailures) {
        if ($combinedOutput.Contains($failureText, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{
                type = "AuthError"
                description = "Authentication error detected"
                recoverable = $true
                suggested_action = "Switch auth method or refresh credentials"
            }
        }
    }

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

    if ($combinedOutput -match "task.*not found" -or
        $combinedOutput -match "invalid task") {
        return @{
            type = "TaskError"
            description = "Task not found or invalid"
            recoverable = $false
            suggested_action = "Skip this task"
        }
    }

    if ($combinedOutput -match "max iterations reached" -or
        $combinedOutput -match "iteration limit") {
        return @{
            type = "MaxIterations"
            description = "Go Mode reached maximum iterations without completion"
            recoverable = $true
            suggested_action = "Retry with increased max iterations or review task complexity"
        }
    }

    return @{
        type = "Crash"
        description = "Unexpected failure or crash (exit code: $ExitCode)"
        recoverable = $true
        suggested_action = "Review output and retry"
    }
}
