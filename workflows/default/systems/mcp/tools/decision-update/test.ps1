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

# ── Setup: Create a Decision to update ──
Write-Host "Setup: Creating test Decision for update tests" -ForegroundColor DarkGray
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 100
    method = 'tools/call'
    params = @{
        name = 'decision_create'
        arguments = @{
            title = 'Original Title'
            context = 'Original context.'
            decision = 'Original decision.'
            rationale = 'Original rationale.'
            consequences = 'Original consequences.'
            alternatives_considered = 'Original alternatives.'
        }
    }
}
$created = $response.result.content[0].text | ConvertFrom-Json
$testDecisionId = $created.decision_id
Write-Host "  Created $testDecisionId" -ForegroundColor DarkGray

# ── Test 1: Update title ──
Write-Host "`nTest: Update Decision title" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'decision_update'
        arguments = @{
            decision_id = $testDecisionId
            title = 'Updated Title'
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }

# Verify via get
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 11
    method = 'tools/call'
    params = @{
        name = 'decision_get'
        arguments = @{ decision_id = $testDecisionId }
    }
}
$fetched = $response.result.content[0].text | ConvertFrom-Json
if ($fetched.title -ne 'Updated Title') { throw "Expected 'Updated Title', got '$($fetched.title)'" }
Write-Host "✓ Title updated and verified via get" -ForegroundColor Green

# ── Test 2: Update a section ──
Write-Host "`nTest: Update context section" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 2
    method = 'tools/call'
    params = @{
        name = 'decision_update'
        arguments = @{
            decision_id = $testDecisionId
            context = 'Updated context with more details about the problem.'
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }

# Verify
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 21
    method = 'tools/call'
    params = @{
        name = 'decision_get'
        arguments = @{ decision_id = $testDecisionId }
    }
}
$fetched = $response.result.content[0].text | ConvertFrom-Json
if ($fetched.sections.Context -ne 'Updated context with more details about the problem.') {
    throw "Context section not updated correctly"
}
# Other sections should be preserved
if ($fetched.sections.Decision -ne 'Original decision.') {
    throw "Decision section was unexpectedly modified"
}
Write-Host "✓ Section updated, other sections preserved" -ForegroundColor Green

# ── Test 3: Update title with special characters (YAML safety) ──
Write-Host "`nTest: Update title with YAML-unsafe characters" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 3
    method = 'tools/call'
    params = @{
        name = 'decision_update'
        arguments = @{
            decision_id = $testDecisionId
            title = "Use gRPC: It's faster & supports streaming"
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }

# Verify round-trip
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 31
    method = 'tools/call'
    params = @{
        name = 'decision_get'
        arguments = @{ decision_id = $testDecisionId }
    }
}
$fetched = $response.result.content[0].text | ConvertFrom-Json
if ($fetched.title -ne "Use gRPC: It's faster & supports streaming") {
    throw "Title with special chars not round-tripped correctly: '$($fetched.title)'"
}
Write-Host "✓ Title with special chars round-tripped correctly" -ForegroundColor Green

# ── Test 4: Update related_decisions ──
Write-Host "`nTest: Update related Decisions" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 4
    method = 'tools/call'
    params = @{
        name = 'decision_update'
        arguments = @{
            decision_id = $testDecisionId
            related_decisions = @('dec-00000001', 'dec-00000003')
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }

# Verify file contains related_decisions
$fileContent = Get-Content -Path $result.file_path -Raw
if ($fileContent -notmatch 'related_decisions:.*dec-00000001.*dec-00000003') {
    throw "related_decisions not written correctly"
}
Write-Host "✓ Related Decisions updated" -ForegroundColor Green

# ── Test 5: Update sets updated_at timestamp ──
Write-Host "`nTest: Update sets updated_at timestamp" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 5
    method = 'tools/call'
    params = @{
        name = 'decision_update'
        arguments = @{
            decision_id = $testDecisionId
            rationale = 'Updated rationale.'
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }

$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 51
    method = 'tools/call'
    params = @{
        name = 'decision_get'
        arguments = @{ decision_id = $testDecisionId }
    }
}
$fetched = $response.result.content[0].text | ConvertFrom-Json
if (-not $fetched.updated_at) { throw "Expected updated_at to be set" }
Write-Host "✓ updated_at timestamp is set" -ForegroundColor Green

# ── Test 6: Update non-existent Decision should fail ──
Write-Host "`nTest: Update non-existent Decision should fail" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 6
    method = 'tools/call'
    params = @{
        name = 'decision_update'
        arguments = @{
            decision_id = 'dec-00000999'
            title = 'Should not work'
        }
    }
}
$errorMsg = if ($response.error) { $response.error.message } else { $response.result.content[0].text }
if ($errorMsg -notmatch 'not found') {
    throw "Expected 'not found' error, got: $errorMsg"
}
Write-Host "✓ Non-existent Decision correctly returns error" -ForegroundColor Green
