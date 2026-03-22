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

# First get a feature to mark
Write-Host "Test: Get next feature first" -ForegroundColor Yellow
$getResponse = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'feature_get_next'
        arguments = @{}
    }
}

if ($getResponse.result) {
    $nextFeature = $getResponse.result.content[0].text | ConvertFrom-Json
    
    if ($nextFeature.feature) {
        $featureId = $nextFeature.feature.id
        
        Write-Host "Test: Mark feature as in-progress" -ForegroundColor Yellow
        $response = Send-McpRequest -Process $Process -Request @{
            jsonrpc = '2.0'
            id = 2
            method = 'tools/call'
            params = @{
                name = 'feature_mark_in_progress'
                arguments = @{
                    feature_id = $featureId
                }
            }
        }
        
        $result = $response.result.content[0].text | ConvertFrom-Json
        Write-Host "✓ $($result.message)" -ForegroundColor Green
        Write-Host "  Feature ID: $($result.feature_id)" -ForegroundColor Gray
        Write-Host "  Status: $($result.old_status) → $($result.new_status)" -ForegroundColor Gray
    } else {
        Write-Host "✓ No features to test with" -ForegroundColor Yellow
    }
} else {
    Write-Host "✗ Could not get next feature" -ForegroundColor Red
}