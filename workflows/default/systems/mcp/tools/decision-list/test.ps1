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

# ── Setup: Create Decisions in different states ──
Write-Host "Setup: Creating test Decisions" -ForegroundColor DarkGray

# Create a proposed Decision
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 100
    method = 'tools/call'
    params = @{
        name = 'decision_create'
        arguments = @{
            title = 'List Test - Proposed Decision'
            context = 'Testing list functionality.'
            decision = 'Created for list test.'
            status = 'proposed'
        }
    }
}
$proposedId = ($response.result.content[0].text | ConvertFrom-Json).decision_id
Write-Host "  Created proposed: $proposedId" -ForegroundColor DarkGray

# Create an accepted Decision
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 101
    method = 'tools/call'
    params = @{
        name = 'decision_create'
        arguments = @{
            title = 'List Test - Accepted Decision'
            context = 'Testing list functionality.'
            decision = 'Created for list test.'
            status = 'accepted'
        }
    }
}
$acceptedId = ($response.result.content[0].text | ConvertFrom-Json).decision_id
Write-Host "  Created accepted: $acceptedId" -ForegroundColor DarkGray

# ── Test 1: List all Decisions ──
Write-Host "`nTest: List all Decisions" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'decision_list'
        arguments = @{}
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }
if ($result.count -lt 2) { throw "Expected at least 2 Decisions, got $($result.count)" }
Write-Host "✓ Listed $($result.count) Decisions" -ForegroundColor Green

# ── Test 2: List Decisions filtered by status ──
Write-Host "`nTest: List proposed Decisions only" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 2
    method = 'tools/call'
    params = @{
        name = 'decision_list'
        arguments = @{
            status = 'proposed'
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }
# All returned Decisions should be proposed
foreach ($dec in $result.decisions) {
    if ($dec.status -ne 'proposed') {
        throw "Expected all Decisions to be proposed, found $($dec.status)"
    }
}
Write-Host "✓ Filtered to $($result.count) proposed Decisions" -ForegroundColor Green

# ── Test 3: List accepted Decisions ──
Write-Host "`nTest: List accepted Decisions only" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 3
    method = 'tools/call'
    params = @{
        name = 'decision_list'
        arguments = @{
            status = 'accepted'
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }
foreach ($dec in $result.decisions) {
    if ($dec.status -ne 'accepted') {
        throw "Expected all Decisions to be accepted, found $($dec.status)"
    }
}
Write-Host "✓ Filtered to $($result.count) accepted Decisions" -ForegroundColor Green

# ── Test 4: Decisions are sorted by id ──
Write-Host "`nTest: Decisions are sorted by id" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 4
    method = 'tools/call'
    params = @{
        name = 'decision_list'
        arguments = @{}
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
$ids = @($result.decisions | ForEach-Object { $_.id })
$sorted = @($ids | Sort-Object)
for ($i = 0; $i -lt $ids.Count; $i++) {
    if ($ids[$i] -ne $sorted[$i]) {
        throw "Decisions not sorted by id: expected $($sorted[$i]) at position $i, got $($ids[$i])"
    }
}
Write-Host "✓ Decisions are sorted by id" -ForegroundColor Green

# ── Test 5: Each Decision has expected fields ──
Write-Host "`nTest: Decision list entries have expected fields" -ForegroundColor Yellow
$firstDec = $result.decisions[0]
$requiredFields = @('id', 'title', 'status', 'file_path', 'file_name')
foreach ($field in $requiredFields) {
    if (-not $firstDec.PSObject.Properties[$field]) {
        throw "Missing required field: $field"
    }
}
Write-Host "✓ All expected fields present" -ForegroundColor Green

# ── Test 6: YAML quoted titles are correctly unquoted in list ──
Write-Host "`nTest: YAML quoted titles are unquoted in list" -ForegroundColor Yellow
$matchedDec = $result.decisions | Where-Object { $_.id -eq $proposedId }
if ($matchedDec -and $matchedDec.title -match "^'") {
    throw "Title still has YAML quotes: $($matchedDec.title)"
}
Write-Host "✓ Titles correctly unquoted in list" -ForegroundColor Green

# ── Test 7: Invalid status filter should fail (path traversal prevention) ──
Write-Host "`nTest: Invalid status filter should fail" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 7
    method = 'tools/call'
    params = @{
        name = 'decision_list'
        arguments = @{
            status = '..\..\..\'
        }
    }
}
$errorMsg = if ($response.error) { $response.error.message } else { $response.result.content[0].text }
if ($errorMsg -notmatch 'Invalid status') {
    throw "Expected 'Invalid status' error, got: $errorMsg"
}
Write-Host "✓ Invalid status filter correctly rejected" -ForegroundColor Green
