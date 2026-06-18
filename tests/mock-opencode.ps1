#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock OpenCode CLI for harness adapter tests.
.DESCRIPTION
    Captures OpenCode args and emits the JSON event sequence used by the
    current OpenCode CLI.
#>

$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
$promptFile = Join-Path $logDir "mock-opencode-prompt.log"
$argsFile = Join-Path $logDir "mock-opencode-args.log"
$cwdFile = Join-Path $logDir "mock-opencode-cwd.log"

($args -join "`n") | Set-Content -Path $argsFile -Encoding UTF8
(Get-Location).Path | Set-Content -Path $cwdFile -Encoding UTF8

if ($args -contains "--session") {
    [Console]::Error.WriteLine("Session not found")
    exit 1
}

$attachedPromptFile = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "--file" -and ($i + 1) -lt $args.Count) {
        $attachedPromptFile = [string]$args[$i + 1]
        break
    }
}

$prompt = if ($args.Count -gt 0) { [string]$args[-1] } else { "" }
if ($attachedPromptFile -and (Test-Path -LiteralPath $attachedPromptFile)) {
    $prompt = Get-Content -LiteralPath $attachedPromptFile -Raw
}
$prompt | Set-Content -Path $promptFile -Encoding UTF8

if ($env:DOTBOT_MOCK_OPENCODE_MODE -eq "error") {
    [Console]::Error.WriteLine("Mock OpenCode error")
    exit 43
}

$sessionId = "ses_mockopencode123"
$startMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$textMs = $startMs + 100
$finishMs = $startMs + 200

@{
    type = "step_start"
    timestamp = $startMs
    sessionID = $sessionId
    part = @{
        id = "prt_start"
        messageID = "msg_1"
        sessionID = $sessionId
        snapshot = "mock-snapshot"
        type = "step-start"
    }
} | ConvertTo-Json -Depth 6 -Compress | Write-Output

@{
    type = "text"
    timestamp = $textMs
    sessionID = $sessionId
    part = @{
        id = "prt_text"
        messageID = "msg_1"
        sessionID = $sessionId
        type = "text"
        text = "DOTBOT_OPENCODE_MOCK_OK"
    }
} | ConvertTo-Json -Depth 6 -Compress | Write-Output

@{
    type = "step_finish"
    timestamp = $finishMs
    sessionID = $sessionId
    part = @{
        id = "prt_finish"
        reason = "stop"
        snapshot = "mock-snapshot"
        messageID = "msg_1"
        sessionID = $sessionId
        type = "step-finish"
        tokens = @{
            total = 12
            input = 9
            output = 3
            reasoning = 0
            cache = @{
                write = 0
                read = 0
            }
        }
        cost = 0.0
    }
} | ConvertTo-Json -Depth 8 -Compress | Write-Output

exit 0
