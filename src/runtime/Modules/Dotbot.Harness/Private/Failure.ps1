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
        # First: rate-limit texts sometimes mention accounts/plans and must not
        # leak into AuthError (#623). dotbot can drive several harnesses
        # (ClaudeCodeAdapter, CodexAdapter, AntigravityAdapter, ...), each with
        # its own provider's wording — grouped below by source so a phrase can
        # be traced back to where it was verified.
        Type             = 'RateLimitError'
        Description      = 'Provider usage/rate limit reached'
        Recoverable      = $true
        SuggestedAction  = 'Wait for the limit to reset, then retry'
        Substrings       = @(
            # Cross-provider (generic HTTP 429 wording)
            'rate limit', 'rate-limit', 'rate_limit', 'too many requests',
            # Claude (Anthropic) CLI — verbatim from the reported bug's log
            'hit your limit', 'usage limit', 'overloaded_error',
            # Codex (OpenAI) CLI — openai/codex issues #690, #6792, #30041;
            # OpenAI API error-code docs
            'rate_limit_exceeded', 'insufficient_quota', 'quota exceeded',
            # Antigravity (Gemini) CLI — Gemini API error-code-429 reference;
            # 'resource_exhausted' is the gRPC/API status enum, the other two
            # are the human-readable message wording Google's docs quote
            'resource_exhausted', 'resource exhausted', 'resource has been exhausted'
        )
        # 429 only with HTTP-ish context — a bare \b429\b would false-positive
        # on ordinary numbers ("returned 429 items").
        Regex            = '(?:http|status|error|code)\s*:?\s*429\b|\b429\s+too\s+many'
    },
    @{
        Type             = 'AuthError'
        Description      = 'Authentication error detected'
        Recoverable      = $true
        SuggestedAction  = 'Switch auth method or refresh credentials'
        Substrings       = @(
            'authentication failed', 'invalid api key', 'not authenticated', 'unauthorized',
            'oauth token', 'token expired', 'authentication_error', 'please run /login',
            're-authenticate', 'session expired', 'credentials'
        )
        Regex            = '\b401\b'
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
        }
        if (-not $matched -and $rule.Regex) {
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

function Get-RateLimitResetTime {
    <#
    .SYNOPSIS
    Best-effort parse of a provider rate-limit reset hint out of error text.

    .DESCRIPTION
    Recognises the common phrasings provider CLIs emit alongside a usage/rate
    limit — Claude's "resets 3:30pm" / "resets at 15:30", and the relative
    "try again in 45 seconds" / "retry after 2 minutes" / OpenAI's abbreviated
    "please try again in 3s" — and converts them to an absolute local DateTime
    with a small safety margin added. A clock time already in the past is
    interpreted as tomorrow.

    The message format is NOT a provider contract — callers must treat the
    result as a hint and keep a fallback path for $null (no parseable hint).
    #>
    [CmdletBinding()]
    param([string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return $null }

    $safetyMargin = [TimeSpan]::FromSeconds(120)
    $now = Get-Date

    # "try again in N seconds/minutes/hours" / "retry after N ..." — accepts
    # both spelled-out units and OpenAI's abbreviated form ("try again in 3s").
    if ($ErrorText -match '(?:try\s+again|retry)\s+(?:in|after)\s+(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\b') {
        $n = [int]$Matches[1]
        $unit = $Matches[2].ToLowerInvariant()
        $span = if ($unit.StartsWith('s')) { [TimeSpan]::FromSeconds($n) }
                elseif ($unit.StartsWith('m')) { [TimeSpan]::FromMinutes($n) }
                else { [TimeSpan]::FromHours($n) }
        return $now.Add($span).Add($safetyMargin)
    }

    # "resets 3:30pm" / "resets at 15:30" / "resets 4pm" — interpreted in the
    # machine's local time zone. The CLI does not state one explicitly, but
    # since the harness CLI (claude.exe / codex / antigravity) runs as a
    # *child process on this same machine*, it necessarily renders the reset
    # clock time using that machine's own local clock — there is no separate
    # server timezone to reconcile with. The deferral cap in the caller
    # (rate_limit_max_deferrals) is still kept as defense-in-depth in case a
    # future CLI version formats this differently (e.g. an explicit UTC
    # offset) in a way this parser does not yet understand.
    if ($ErrorText -match 'resets?\s*(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b') {
        $hour = [int]$Matches[1]
        $minute = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $meridiem = if ($Matches[3]) { $Matches[3].ToLowerInvariant() } else { $null }
        # A bare hour with no minutes and no am/pm ("resets 2026") is too
        # ambiguous to act on — refuse rather than sleep to a random time.
        if (-not $Matches[2] -and -not $meridiem) { return $null }
        if ($meridiem -eq 'pm' -and $hour -lt 12) { $hour += 12 }
        if ($meridiem -eq 'am' -and $hour -eq 12) { $hour = 0 }
        if ($hour -gt 23 -or $minute -gt 59) { return $null }
        $candidate = $now.Date.AddHours($hour).AddMinutes($minute)
        if ($candidate -le $now) { $candidate = $candidate.AddDays(1) }
        return $candidate.Add($safetyMargin)
    }

    return $null
}
