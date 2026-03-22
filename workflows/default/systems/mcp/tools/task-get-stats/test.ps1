#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [System.Diagnostics.Process]$Process
)

. "$PSScriptRoot\..\..\dotbot-mcp-helpers.ps1"

function Send-McpRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Request,
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )
    
    $json = $Request | ConvertTo-Json -Depth 10 -Compress
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
    Start-Sleep -Milliseconds 100
    $response = $Process.StandardOutput.ReadLine()
    
    if ($response) {
        return $response | ConvertFrom-Json
    }
    return $null
}

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