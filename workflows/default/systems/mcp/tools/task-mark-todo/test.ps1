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

Write-Host "Test: Create a test feature first" -ForegroundColor Yellow
$createResponse = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'feature_create'
        arguments = @{
            name = 'Test Feature for Move'
            description = 'A test feature to demonstrate moving between statuses'
            category = 'feature'
            priority = 25
        }
    }
}
$createResult = $createResponse.result.content[0].text | ConvertFrom-Json
$testFeatureId = $createResult.feature_id
Write-Host "✓ Created test feature with ID: $testFeatureId" -ForegroundColor Green

Write-Host "`nTest: Start feature (move to in-progress)" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 2
    method = 'tools/call'
    params = @{
        name = 'feature_start'
        arguments = @{
            feature_id = $testFeatureId
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ $($result.message)" -ForegroundColor Green
Write-Host "  Old path: $($result.old_path)" -ForegroundColor Gray
Write-Host "  New path: $($result.new_path)" -ForegroundColor Gray

Write-Host "`nTest: Mark feature as done" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 3
    method = 'tools/call'
    params = @{
        name = 'feature_mark_done'
        arguments = @{
            feature_id = $testFeatureId
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ $($result.message)" -ForegroundColor Green

Write-Host "`nTest: Try to mark as done again (should handle gracefully)" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 4
    method = 'tools/call'
    params = @{
        name = 'feature_mark_done'
        arguments = @{
            feature_id = $testFeatureId
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ $($result.message)" -ForegroundColor Green