#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Mock Antigravity CLI for harness adapter tests.
#>

$logDir = if ($env:DOTBOT_MOCK_LOG_DIR) { $env:DOTBOT_MOCK_LOG_DIR } else { [System.IO.Path]::GetTempPath() }
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

($args -join "`n") | Set-Content -Path (Join-Path $logDir "mock-antigravity-args.log") -Encoding UTF8
(Get-Location).Path | Set-Content -Path (Join-Path $logDir "mock-antigravity-cwd.log") -Encoding UTF8

$prompt = ""
if ($args.Count -gt 0) {
    $prompt = [string]$args[-1]
}
$prompt | Set-Content -Path (Join-Path $logDir "mock-antigravity-prompt.log") -Encoding UTF8

if ($env:DOTBOT_MOCK_ANTIGRAVITY_MODE -eq "slow-stream") {
    Write-Output "DOTBOT_ANTIGRAVITY_STREAM_FIRST"
    [Console]::Out.Flush()
    Start-Sleep -Seconds 3
    Write-Output "DOTBOT_ANTIGRAVITY_STREAM_DONE"
    exit 0
}

Write-Output "DOTBOT_ANTIGRAVITY_MOCK_OK"
exit 0
