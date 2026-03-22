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

Write-Host "Test: Create a new feature" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'feature_create'
        arguments = @{
            name = 'User Authentication'
            description = 'Implement secure user authentication with email/password login'
            category = 'core'
            priority = 1
            effort = 'L'
            dependencies = @()
            acceptance_criteria = @(
                'Users can register with email and password'
                'Users can log in with credentials'
                'Sessions are secure and expire appropriately'
                'Password reset functionality works'
            )
            steps = @(
                'Set up authentication middleware'
                'Create user model and database schema'
                'Implement registration endpoint'
                'Implement login endpoint'
                'Add session management'
                'Create password reset flow'
            )
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ Feature created with ID: $($result.feature_id)" -ForegroundColor Green
Write-Host "  File: $($result.file_path)" -ForegroundColor Gray