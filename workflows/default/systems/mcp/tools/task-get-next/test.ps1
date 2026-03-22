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

Write-Host "Test: Get next feature to work on" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'feature_get_next'
        arguments = @{}
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if ($result.success) {
    if ($result.feature) {
        Write-Host "✓ Next feature retrieved:" -ForegroundColor Green
        Write-Host "  ID: $($result.feature.id)" -ForegroundColor Gray
        Write-Host "  Name: $($result.feature.name)" -ForegroundColor Gray
        Write-Host "  Priority: $($result.feature.priority)" -ForegroundColor Gray
        Write-Host "  Effort: $($result.feature.effort)" -ForegroundColor Gray
        Write-Host "  Category: $($result.feature.category)" -ForegroundColor Gray
    } else {
        Write-Host "✓ $($result.message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "✗ $($result.message)" -ForegroundColor Red
}