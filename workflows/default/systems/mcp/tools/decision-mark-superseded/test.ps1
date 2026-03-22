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

# ── Setup: Create two Decisions (one to supersede, one as replacement) ──
Write-Host "Setup: Creating Decisions for supersede test" -ForegroundColor DarkGray

$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 100
    method = 'tools/call'
    params = @{
        name = 'decision_create'
        arguments = @{
            title = 'Old Decision'
            context = 'This will be superseded.'
            decision = 'Original approach.'
            status = 'proposed'
        }
    }
}
$oldId = ($response.result.content[0].text | ConvertFrom-Json).decision_id
$oldFilePath = ($response.result.content[0].text | ConvertFrom-Json).file_path
Write-Host "  Created old: $oldId (proposed)" -ForegroundColor DarkGray

$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 101
    method = 'tools/call'
    params = @{
        name = 'decision_create'
        arguments = @{
            title = 'New Decision'
            context = 'This replaces the old decision.'
            decision = 'Better approach.'
            status = 'accepted'
        }
    }
}
$newId = ($response.result.content[0].text | ConvertFrom-Json).decision_id
Write-Host "  Created new: $newId (accepted)" -ForegroundColor DarkGray

# ── Test 1: Supersede a proposed Decision ──
Write-Host "`nTest: Supersede a proposed Decision" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'decision_mark_superseded'
        arguments = @{
            decision_id = $oldId
            superseded_by = $newId
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }
if ($result.file_path -notlike '*superseded*') { throw "Expected file moved to superseded directory" }
if ($result.superseded_by -ne $newId) { throw "Expected superseded_by=$newId" }
Write-Host "✓ Decision superseded, file moved to superseded/" -ForegroundColor Green

# ── Test 2: Verify status and superseded_by in frontmatter ──
Write-Host "`nTest: Verify superseded status and superseded_by field" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 2
    method = 'tools/call'
    params = @{
        name = 'decision_get'
        arguments = @{ decision_id = $oldId }
    }
}
$fetched = $response.result.content[0].text | ConvertFrom-Json
if ($fetched.status -ne 'superseded') { throw "Expected status=superseded, got $($fetched.status)" }
if ($fetched.superseded_by -ne $newId) { throw "Expected superseded_by=$newId, got $($fetched.superseded_by)" }
Write-Host "✓ Status is superseded, superseded_by is correct" -ForegroundColor Green

# ── Test 3: Original file removed from proposed/ ──
Write-Host "`nTest: Original file removed from proposed/" -ForegroundColor Yellow
if (Test-Path $oldFilePath) {
    throw "Original file should have been removed from proposed/"
}
Write-Host "✓ Original file cleaned up" -ForegroundColor Green

# ── Test 4: Supersede an accepted Decision ──
Write-Host "`nTest: Supersede an accepted Decision" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 102
    method = 'tools/call'
    params = @{
        name = 'decision_create'
        arguments = @{
            title = 'Accepted To Supersede'
            context = 'Will be accepted then superseded.'
            decision = 'Temp decision.'
            status = 'accepted'
        }
    }
}
$acceptedId = ($response.result.content[0].text | ConvertFrom-Json).decision_id

$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 41
    method = 'tools/call'
    params = @{
        name = 'decision_mark_superseded'
        arguments = @{
            decision_id = $acceptedId
            superseded_by = $newId
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
if (-not $result.success) { throw "Expected success=true" }
Write-Host "✓ Accepted Decision superseded successfully" -ForegroundColor Green

# ── Test 5: Supersede without superseded_by should fail ──
Write-Host "`nTest: Supersede without superseded_by should fail" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 5
    method = 'tools/call'
    params = @{
        name = 'decision_mark_superseded'
        arguments = @{
            decision_id = 'dec-00000001'
        }
    }
}
$errorMsg = if ($response.error) { $response.error.message } else { $response.result.content[0].text }
if ($errorMsg -notmatch 'required') {
    throw "Expected 'required' error for missing superseded_by, got: $errorMsg"
}
Write-Host "✓ Missing superseded_by correctly rejected" -ForegroundColor Green

# ── Test 6: Supersede non-existent Decision should fail ──
Write-Host "`nTest: Supersede non-existent Decision should fail" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 6
    method = 'tools/call'
    params = @{
        name = 'decision_mark_superseded'
        arguments = @{
            decision_id = 'dec-00000999'
            superseded_by = 'dec-00000001'
        }
    }
}
$errorMsg = if ($response.error) { $response.error.message } else { $response.result.content[0].text }
if ($errorMsg -notmatch 'not found') {
    throw "Expected 'not found' error, got: $errorMsg"
}
Write-Host "✓ Non-existent Decision correctly returns error" -ForegroundColor Green
