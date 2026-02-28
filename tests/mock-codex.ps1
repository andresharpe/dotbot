#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock Codex CLI for testing. Emits canned JSONL events.
.DESCRIPTION
    Mimics codex exec behavior: reads prompt from args,
    emits JSONL events matching Codex --json format,
    and logs the received prompt for assertion.
#>

# No param block — use automatic $args so -m etc. don't fail parameter binding

# Determine log file location
$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
$logFile = Join-Path $logDir "mock-codex-prompt.log"
$modeFile = Join-Path $logDir "mock-codex-mode.txt"

# Determine mock mode (normal, rate-limit, error)
$mode = "normal"
if (Test-Path $modeFile) {
    $mode = (Get-Content $modeFile -Raw).Trim()
}

# Extract prompt from args (after "--" or last arg)
$prompt = ""
$foundSeparator = $false
foreach ($a in $args) {
    if ($foundSeparator) {
        $prompt += $a + " "
    }
    if ($a -eq "--") {
        $foundSeparator = $true
    }
}
$prompt = $prompt.Trim()

if (-not $prompt -and $args.Count -gt 0) {
    $prompt = "$($args[-1])"
}

# Log the received prompt
$prompt | Set-Content -Path $logFile -Encoding UTF8

# Emit JSONL events based on mode
switch ($mode) {
    "rate-limit" {
        $threadEvent = @{ type = "thread.started"; thread_id = "mock-thread-001" } | ConvertTo-Json -Compress
        Write-Output $threadEvent
        $errorEvent = @{ type = "error"; message = "Rate limit exceeded. Too many requests (429)." } | ConvertTo-Json -Compress
        Write-Output $errorEvent
    }

    "error" {
        [Console]::Error.WriteLine("Error: Mock Codex error for testing")
        exit 1
    }

    default {
        # Normal mode: emit Codex JSONL sequence

        # 1. Thread started
        $threadEvent = @{
            type = "thread.started"
            thread_id = "mock-thread-001"
        } | ConvertTo-Json -Compress
        Write-Output $threadEvent

        # 2. Turn started
        $turnEvent = @{ type = "turn.started" } | ConvertTo-Json -Compress
        Write-Output $turnEvent

        # 3. Message completed with text
        $msgEvent = @{
            type = "message.completed"
            content = "Mock Codex response: Task completed successfully."
            usage = @{
                input_tokens = 120
                output_tokens = 35
            }
        } | ConvertTo-Json -Depth 5 -Compress
        Write-Output $msgEvent

        # 4. Turn completed
        $turnDoneEvent = @{
            type = "turn.completed"
            usage = @{
                input_tokens = 120
                output_tokens = 35
            }
        } | ConvertTo-Json -Depth 5 -Compress
        Write-Output $turnDoneEvent
    }
}

exit 0
