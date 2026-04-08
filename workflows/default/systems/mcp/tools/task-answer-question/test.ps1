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

# ── Setup: create a task in needs-input with a pending question ──────────────
$testTaskId = "test-$(New-Guid)"
$needsInputDir = Join-Path $env:DOTBOT_PROJECT_ROOT ".bot\workspace\tasks\needs-input"
if (-not (Test-Path $needsInputDir)) {
    New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
}

$testTask = @{
    id = $testTaskId
    name = "Test Task for Answer"
    status = "needs-input"
    pending_question = @{
        id = "q-001"
        question = "Which approach should we take?"
        asked_at = (Get-Date).ToUniversalTime().ToString("o")
        options = @(
            @{ key = "A"; label = "Option Alpha"; rationale = "First option" }
            @{ key = "B"; label = "Option Beta";  rationale = "Second option" }
        )
        recommendation = "A"
    }
    questions_resolved = @()
    created_at = (Get-Date).ToUniversalTime().ToString("o")
}

$taskFilePath = Join-Path $needsInputDir "$testTaskId.json"
$testTask | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFilePath -Encoding UTF8

# ── Test 1: Answer with a valid option key ───────────────────────────────────
Write-Host "Test: Answer task question with option key" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'task_answer_question'
        arguments = @{
            task_id = $testTaskId
            answer  = 'A'
        }
    }
}

Assert-NotNull $response "Response should not be null"
$result = $response.result.content[0].text | ConvertFrom-Json
Assert-Equal $true $result.success "Should succeed"
Assert-Equal 'analysing' $result.new_status "Task should move to analysing"
Assert-Equal 'option' $result.answer_type "Answer type should be 'option'"
Assert-Equal 0 $result.attachments_count "No attachments"

# ── Setup for Test 2: create another task ───────────────────────────────────
$testTaskId2 = "test-$(New-Guid)"
$testTask2 = $testTask.PSObject.Copy()
$testTask2.id = $testTaskId2
$testTask2.questions_resolved = @()
$taskFilePath2 = Join-Path $needsInputDir "$testTaskId2.json"
$testTask2 | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFilePath2 -Encoding UTF8

# ── Test 2: Answer with attachments ─────────────────────────────────────────
Write-Host "Test: Answer task question with attachments metadata" -ForegroundColor Yellow
$response2 = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 2
    method = 'tools/call'
    params = @{
        name = 'task_answer_question'
        arguments = @{
            task_id     = $testTaskId2
            answer      = 'B'
            attachments = @(
                @{ name = 'notes.md'; size = 1024; path = '.bot/workspace/attachments/test/q-001/notes.md' }
            )
        }
    }
}

Assert-NotNull $response2 "Response should not be null"
$result2 = $response2.result.content[0].text | ConvertFrom-Json
Assert-Equal $true $result2.success "Should succeed"
Assert-Equal 1 $result2.attachments_count "Should report 1 attachment"

# Verify attachment is persisted in questions_resolved
$analysingDir = Join-Path $env:DOTBOT_PROJECT_ROOT ".bot\workspace\tasks\analysing"
$savedTask = Get-ChildItem -Path $analysingDir -Filter "$testTaskId2.json" -ErrorAction SilentlyContinue |
    Select-Object -First 1 | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
Assert-NotNull $savedTask "Task should be in analysing dir"
$resolved = @($savedTask.questions_resolved)[0]
Assert-NotNull $resolved.attachments "Resolved question should have attachments"
Assert-Equal 'notes.md' $resolved.attachments[0].name "Attachment name should be preserved"

# ── Test 3: Missing task_id returns error ────────────────────────────────────
Write-Host "Test: Error on missing task_id" -ForegroundColor Yellow
$response3 = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 3
    method = 'tools/call'
    params = @{
        name = 'task_answer_question'
        arguments = @{
            answer = 'A'
        }
    }
}

Assert-NotNull $response3 "Response should not be null"
# Should return an error (isError or exception in result)
$isError = $response3.result.isError -or $response3.error
Assert-Equal $true ([bool]$isError) "Missing task_id should return an error"

Write-Host "All task-answer-question tests passed" -ForegroundColor Green
