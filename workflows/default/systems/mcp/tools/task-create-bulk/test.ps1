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

Write-Host "Test: Create multiple features in bulk" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'feature_create_bulk'
        arguments = @{
            features = @(
                @{
                    name = 'Database Setup'
                    description = 'Set up PostgreSQL database with initial schema'
                    category = 'infrastructure'
                    effort = 'M'
                    steps = @(
                        'Install PostgreSQL'
                        'Create database'
                        'Design initial schema'
                        'Create migrations'
                    )
                },
                @{
                    name = 'User Model'
                    description = 'Create user model with authentication fields'
                    category = 'core'
                    effort = 'S'
                    acceptance_criteria = @(
                        'User model has email, password_hash fields'
                        'Email validation works'
                        'Password hashing implemented'
                    )
                },
                @{
                    name = 'API Authentication'
                    description = 'Implement JWT-based API authentication'
                    category = 'core'
                    effort = 'L'
                    acceptance_criteria = @(
                        'JWT tokens are generated on login'
                        'Tokens expire after configured time'
                        'Protected routes require valid token'
                    )
                }
            )
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ $($result.message)" -ForegroundColor Green
Write-Host "  Created: $($result.created_count) features" -ForegroundColor Gray
Write-Host "  Errors: $($result.error_count)" -ForegroundColor Gray

if ($result.created_features.Count -gt 0) {
    Write-Host "`nCreated features:" -ForegroundColor Yellow
    foreach ($feature in $result.created_features) {
        Write-Host "  - $($feature.name) (Priority: $($feature.priority))" -ForegroundColor Gray
    }
}