#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock Claude CLI for testing. Emits canned stream-json events.
.DESCRIPTION
    Mimics claude.exe behavior: reads prompt from stdin or args,
    emits stream-json events, and logs the received prompt for assertion.
#>

# No param block — use automatic $args so --model etc. don't fail parameter binding

# Determine log file location
$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
$logFile = Join-Path $logDir "mock-claude-prompt.log"
$modeFile = Join-Path $logDir "mock-claude-mode.txt"
$argsFile = Join-Path $logDir "mock-claude-args.log"

# Log all received args for test assertions
($args -join "`n") | Set-Content -Path $argsFile -Encoding UTF8

# Determine mock mode (normal, rate-limit, error)
$mode = "normal"
if (Test-Path $modeFile) {
    $mode = (Get-Content $modeFile -Raw).Trim()
}

# Extract prompt from args (after "--") or from -p flag
$prompt = ""
$foundSeparator = $false
$nextIsPrompt = $false
foreach ($a in $args) {
    if ($nextIsPrompt) {
        $prompt = $a
        $nextIsPrompt = $false
        continue
    }
    if ($a -eq "-p" -or $a -eq "--print") {
        # -p with a value means prompt
        if ($a -eq "-p") { $nextIsPrompt = $true }
        continue
    }
    if ($foundSeparator) {
        $prompt += $a + " "
    }
    if ($a -eq "--") {
        $foundSeparator = $true
    }
}
$prompt = $prompt.Trim()

# Stdin fallback: prompt may be piped via stdin to avoid Windows cmd-line length limits (#167)
# Check stdin before the last-arg fallback so flags like --verbose aren't mistaken for prompts
if (-not $prompt -and [Console]::IsInputRedirected) {
    try {
        $prompt = [Console]::In.ReadToEnd().Trim()
    } catch {
        # stdin not available or already closed — ignore
    }
}

# Fallback: if -- was consumed by PowerShell's argument parser,
# the prompt is the last non-flag argument
if (-not $prompt -and $args.Count -gt 0) {
    $prompt = "$($args[-1])"
}

# Log the received prompt
$prompt | Set-Content -Path $logFile -Encoding UTF8

# Emit stream-json events based on mode
switch ($mode) {
    "rate-limit" {
        # Emit a rate limit response
        $rateLimitJson = @{
            type    = "error"
            error   = "rate_limit"
            message = @{
                content = @(
                    @{
                        type = "text"
                        text = "You've hit your limit for opus. Your limit resets at 3:00 PM EST."
                    }
                )
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $rateLimitJson
    }

    "error" {
        # Emit an error and exit with non-zero code
        [Console]::Error.WriteLine("Error: Mock error for testing")
        exit 1
    }

    default {
        # Normal mode: emit a minimal valid stream-json sequence

        # 1. Init/config event
        $initEvent = @{
            type    = "system"
            subtype = "init"
            model   = "opus"
            cwd     = (Get-Location).Path
        } | ConvertTo-Json -Compress
        Write-Output $initEvent

        # 2. Assistant message with text
        $assistantEvent = @{
            type    = "assistant"
            message = @{
                content = @(
                    @{
                        type = "text"
                        text = "Mock response: I have completed the requested task successfully."
                    }
                )
                usage   = @{
                    input_tokens  = 150
                    output_tokens = 42
                }
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $assistantEvent

        # 3. Result event
        $resultEvent = @{
            type        = "result"
            subtype     = "success"
            duration_ms = 1234
            num_turns   = 1
            total_cost_usd = 0.005
            usage       = @{
                input_tokens               = 150
                output_tokens              = 42
                cache_read_input_tokens    = 0
                cache_creation_input_tokens = 0
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $resultEvent
    }
}

exit 0
