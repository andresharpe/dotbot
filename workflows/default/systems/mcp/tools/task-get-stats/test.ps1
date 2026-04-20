#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [System.Diagnostics.Process]$Process
)

. "$PSScriptRoot\..\..\dotbot-mcp-helpers.ps1"
Import-Module "$PSScriptRoot\..\..\..\..\..\..\tests\Test-Helpers.psm1" -Force

Write-Host "Test: Get feature statistics" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'feature_get_stats'
        arguments = @{}
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ Statistics retrieved:" -ForegroundColor Green
Write-Host "  Total features: $($result.total_features)" -ForegroundColor Gray
Write-Host "  Passing: $($result.passing)" -ForegroundColor Gray
Write-Host "  In progress: $($result.in_progress)" -ForegroundColor Gray
Write-Host "  Todo: $($result.todo)" -ForegroundColor Gray
Write-Host "  Percentage complete: $($result.percentage_complete)%" -ForegroundColor Gray
Write-Host "  Days effort remaining: $($result.days_effort_remaining)" -ForegroundColor Gray
Write-Host "  Summary: $($result.summary)" -ForegroundColor Gray