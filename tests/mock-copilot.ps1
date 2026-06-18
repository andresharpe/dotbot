#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock GitHub Copilot CLI for harness adapter tests.
.DESCRIPTION
    Captures Copilot args and emits representative JSON events with nested tool
    argument shapes so the adapter's activity-log detail extraction is covered.
#>

$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
$promptFile = Join-Path $logDir "mock-copilot-prompt.log"
$argsFile = Join-Path $logDir "mock-copilot-args.log"
$cwdFile = Join-Path $logDir "mock-copilot-cwd.log"

($args -join "`n") | Set-Content -Path $argsFile -Encoding UTF8
(Get-Location).Path | Set-Content -Path $cwdFile -Encoding UTF8

$prompt = ""
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "-p" -and ($i + 1) -lt $args.Count) {
        $prompt = [string]$args[$i + 1]
        break
    }
}
$prompt | Set-Content -Path $promptFile -Encoding UTF8

@{
    type = "session.started"
    session_id = "mock-copilot-session"
} | ConvertTo-Json -Compress | Write-Output

@{
    type = "tool_call"
    name = "bash"
    arguments = (@{ cmd = "pwsh tests/Run-Tests.ps1 -Layer 1" } | ConvertTo-Json -Compress)
} | ConvertTo-Json -Depth 6 -Compress | Write-Output

@{
    type = "tool_call"
    tool = "read"
    input = @{
        parameters = @{
            path = "src/runtime/Modules/Dotbot.Harness/Adapters/CopilotAdapter.ps1"
        }
    }
} | ConvertTo-Json -Depth 8 -Compress | Write-Output

@{
    type = "message.delta"
    delta = "DOTBOT_COPILOT_"
} | ConvertTo-Json -Compress | Write-Output

@{
    type = "message.delta"
    delta = "MOCK_OK"
} | ConvertTo-Json -Compress | Write-Output

@{
    type = "done"
    usage = @{
        input_tokens = 8
        output_tokens = 2
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output

exit 0
