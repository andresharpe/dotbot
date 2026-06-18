#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock Codex CLI for harness adapter tests.
.DESCRIPTION
    Mimics the current `codex exec --json` JSONL shape closely enough to
    validate dotbot argument construction and stream parsing.
#>

$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
$promptFile = Join-Path $logDir "mock-codex-prompt.log"
$argsFile = Join-Path $logDir "mock-codex-args.log"
$cwdFile = Join-Path $logDir "mock-codex-cwd.log"

($args -join "`n") | Set-Content -Path $argsFile -Encoding UTF8
(Get-Location).Path | Set-Content -Path $cwdFile -Encoding UTF8

$prompt = ""
if ([Console]::IsInputRedirected) {
    try { $prompt = [Console]::In.ReadToEnd().Trim() } catch { $prompt = "" }
}
if (-not $prompt -and $args.Count -gt 0) {
    $prompt = [string]$args[-1]
}
$prompt | Set-Content -Path $promptFile -Encoding UTF8

if ($env:DOTBOT_MOCK_CODEX_MODE -eq "error") {
    [Console]::Error.WriteLine("Mock Codex error")
    exit 42
}

@{
    type = "thread.started"
    thread_id = "mock-codex-thread"
} | ConvertTo-Json -Compress | Write-Output

@{
    type = "turn.started"
} | ConvertTo-Json -Compress | Write-Output

@{
    type = "item.completed"
    item = @{
        id = "item_0"
        type = "agent_message"
        text = "DOTBOT_CODEX_MOCK_OK"
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output

@{
    type = "turn.completed"
    usage = @{
        input_tokens = 10
        cached_input_tokens = 0
        output_tokens = 3
        reasoning_output_tokens = 0
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output

exit 0
