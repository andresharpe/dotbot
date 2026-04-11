#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock Gemini CLI for testing. Emits canned stream-json events.
.DESCRIPTION
    Mimics gemini -p behavior: reads prompt from args,
    emits stream-json events matching Gemini --output-format stream-json format,
    and logs the received prompt for assertion.
#>

# No param block — use automatic $args so -m etc. don't fail parameter binding

# Determine log file location
$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
$logFile = Join-Path $logDir "mock-gemini-prompt.log"
$modeFile = Join-Path $logDir "mock-gemini-mode.txt"

# Determine mock mode (normal, rate-limit, error)
$mode = "normal"
if (Test-Path $modeFile) {
    $mode = (Get-Content $modeFile -Raw).Trim()
}

# Extract prompt from args (after -p flag or last arg)
$prompt = ""
$nextIsPrompt = $false
foreach ($a in $args) {
    if ($nextIsPrompt) {
        $prompt = $a
        $nextIsPrompt = $false
        continue
    }
    if ($a -eq "-p") {
        $nextIsPrompt = $true
    }
}

if (-not $prompt -and $args.Count -gt 0) {
    $prompt = "$($args[-1])"
}

# Log the received prompt
$prompt | Set-Content -Path $logFile -Encoding UTF8

# Emit stream-json events based on mode
switch ($mode) {
    "rate-limit" {
        $initEvent = @{
            type = "system"
            subtype = "init"
            model = "gemini-3-pro-preview"
            cwd = (Get-Location).Path
        } | ConvertTo-Json -Compress
        Write-Output $initEvent

        $errorEvent = @{
            type = "error"
            message = "Quota exceeded for gemini-3-pro-preview. Please wait and retry."
        } | ConvertTo-Json -Compress
        Write-Output $errorEvent
    }

    "error" {
        [Console]::Error.WriteLine("Error: Mock Gemini error for testing")
        exit 1
    }

    default {
        # Normal mode: emit Gemini stream-json sequence (Claude-like format)

        # 1. Init/config event
        $initEvent = @{
            type    = "system"
            subtype = "init"
            model   = "gemini-3-pro-preview"
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
                        text = "Mock Gemini response: Task completed successfully."
                    }
                )
                usage   = @{
                    input_tokens  = 100
                    output_tokens = 30
                }
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $assistantEvent

        # 3. Result event
        $resultEvent = @{
            type        = "result"
            subtype     = "success"
            duration_ms = 987
            num_turns   = 1
            total_cost_usd = 0.003
            usage       = @{
                input_tokens  = 100
                output_tokens = 30
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $resultEvent
    }
}

exit 0
