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

# Failure rules evaluated in order. First match wins. The Pattern can be a
# string array of substrings (matched case-insensitively) or a regex pattern.
$script:HarnessFailureRules = @(
    @{
        Type             = 'AuthError'
        Description      = 'Authentication error detected'
        Recoverable      = $true
        SuggestedAction  = 'Switch auth method or refresh credentials'
        Substrings       = @('authentication failed', 'invalid api key', 'not authenticated', 'unauthorized')
    },
    @{
        Type             = 'VerificationFailed'
        Description      = 'Task verification scripts failed'
        Recoverable      = $true
        SuggestedAction  = 'Review verification output and retry'
        Regex            = 'verification failed|test.*failed|verification_passed.*false'
    },
    @{
        Type             = 'CodeError'
        Description      = 'Code syntax or compilation error'
        Recoverable      = $true
        SuggestedAction  = 'Review code and retry'
        Regex            = 'syntax error|compilation failed|parse error'
    },
    @{
        Type             = 'TaskError'
        Description      = 'Task not found or invalid'
        Recoverable      = $false
        SuggestedAction  = 'Skip this task'
        Regex            = 'task.*not found|invalid task'
    },
    @{
        Type             = 'MaxIterations'
        Description      = 'Go Mode reached maximum iterations without completion'
        Recoverable      = $true
        SuggestedAction  = 'Retry with increased max iterations or review task complexity'
        Regex            = 'max iterations reached|iteration limit'
    }
)

function Get-FailureReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode,

        [string]$Stdout = '',
        [string]$Stderr = '',
        [bool]$TimedOut = $false
    )

    if ($TimedOut) {
        return @{
            type             = 'Timeout'
            description      = 'Harness session exceeded timeout limit'
            recoverable      = $true
            suggested_action = 'Retry with same task'
        }
    }

    $combined = "$Stdout $Stderr"
    foreach ($rule in $script:HarnessFailureRules) {
        $matched = $false
        if ($rule.Substrings) {
            foreach ($s in $rule.Substrings) {
                if ($combined.Contains($s, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $true; break
                }
            }
        } elseif ($rule.Regex) {
            $matched = $combined -match $rule.Regex
        }
        if ($matched) {
            return @{
                type             = $rule.Type
                description      = $rule.Description
                recoverable      = $rule.Recoverable
                suggested_action = $rule.SuggestedAction
            }
        }
    }

    return @{
        type             = 'Crash'
        description      = "Unexpected failure or crash (exit code: $ExitCode)"
        recoverable      = $true
        suggested_action = 'Review output and retry'
    }
}
