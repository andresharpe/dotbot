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

$mockModel = "mock-model"
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "--model" -and ($i + 1) -lt $args.Count) {
        $mockModel = [string]$args[$i + 1]
        break
    }
}

# Capture cwd so tests can assert WorkingDirectory plumbing (#314)
(Get-Location).Path | Set-Content -Path (Join-Path $logDir "mock-claude-cwd.log") -Encoding UTF8

# Determine mock mode (normal, error)
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
    "error" {
        # Emit an error and exit with non-zero code
        [Console]::Error.WriteLine("Error: Mock error for testing")
        exit 1
    }

    "auth-error" {
        # Emit a stream-json error event carrying an auth-expiry message, then
        # exit 0 — mirrors the Claude CLI reporting a mid-run token expiry
        # without a non-zero exit code (#467).
        $errorEvent = @{
            type    = "error"
            message = "OAuth token expired. Please run /login to re-authenticate."
        } | ConvertTo-Json -Compress
        Write-Output $errorEvent
    }

    "hang-after-result" {
        # Emit a valid stream, then stay alive silently. This reproduces a
        # provider CLI held open by a background tool call after task completion.
        $initEvent = @{
            type    = "system"
            subtype = "init"
            model   = $mockModel
            cwd     = (Get-Location).Path
        } | ConvertTo-Json -Compress
        Write-Output $initEvent

        $assistantEvent = @{
            type    = "assistant"
            message = @{
                content = @(
                    @{
                        type = "text"
                        text = "Mock response: task is complete but the provider stays alive."
                    }
                )
                usage   = @{
                    input_tokens  = 150
                    output_tokens = 42
                }
            }
        } | ConvertTo-Json -Depth 10 -Compress
        Write-Output $assistantEvent

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

        Start-Sleep -Seconds 60
    }

    default {
        # Normal mode: emit a minimal valid stream-json sequence

        # 1. Init/config event
        $initEvent = @{
            type    = "system"
            subtype = "init"
            model   = $mockModel
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
