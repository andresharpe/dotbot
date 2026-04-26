# Test task-answer-question tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$needsInputDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\needs-input"
if (-not (Test-Path $needsInputDir)) {
    New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
}

$testTaskId = "test-answer-$(New-Guid)"

@{
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
    updated_at = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $needsInputDir "$testTaskId.json") -Encoding UTF8

try {
    $result = Invoke-TaskAnswerQuestion -Arguments @{
        task_id = $testTaskId
        answer  = 'A'
    }

    Assert-True -Name "task-answer-question: returns success" `
        -Condition ($result.success -eq $true) `
        -Message "Got: $($result.message)"

    Assert-Equal -Name "task-answer-question: new_status is analysing" `
        -Expected 'analysing' `
        -Actual $result.new_status

    Assert-Equal -Name "task-answer-question: answer_type is option" `
        -Expected 'option' `
        -Actual $result.answer_type

    Assert-Equal -Name "task-answer-question: attachments_count is 0" `
        -Expected 0 `
        -Actual $result.attachments_count

    # Verify task moved to analysing/
    $analysingDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\analysing"
    $movedFile = Get-ChildItem -Path $analysingDir -Filter "$testTaskId.json" -ErrorAction SilentlyContinue | Select-Object -First 1

    Assert-True -Name "task-answer-question: file moved to analysing/" `
        -Condition ($null -ne $movedFile) `
        -Message "File not found in analysing/"

    # --- Test 2: answer with attachments ---
    $testTaskId2 = "test-answer-attach-$(New-Guid)"
    @{
        id = $testTaskId2
        name = "Test Task with Attachments"
        status = "needs-input"
        pending_question = @{
            id = "q-002"
            question = "Please provide supporting docs"
            asked_at = (Get-Date).ToUniversalTime().ToString("o")
            options = @(
                @{ key = "A"; label = "Approve"; rationale = "Looks good" }
                @{ key = "B"; label = "Reject";  rationale = "Needs work" }
            )
            recommendation = "B"
        }
        questions_resolved = @()
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        updated_at = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $needsInputDir "$testTaskId2.json") -Encoding UTF8

    $result2 = Invoke-TaskAnswerQuestion -Arguments @{
        task_id     = $testTaskId2
        answer      = 'B'
        attachments = @(
            @{ name = 'notes.md'; size = 1024; path = '.bot/workspace/attachments/test/q-002/notes.md' }
        )
    }

    Assert-True -Name "task-answer-question: attachments returns success" `
        -Condition ($result2.success -eq $true) `
        -Message "Got: $($result2.message)"

    Assert-Equal -Name "task-answer-question: attachments_count is 1" `
        -Expected 1 `
        -Actual $result2.attachments_count

    $savedTask = Get-ChildItem -Path $analysingDir -Filter "$testTaskId2.json" -ErrorAction SilentlyContinue |
        Select-Object -First 1 | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }

    Assert-True -Name "task-answer-question: attachments persisted in questions_resolved" `
        -Condition ($null -ne $savedTask -and $null -ne @($savedTask.questions_resolved)[0].attachments) `
        -Message "Attachments not found in resolved question"

    Assert-Equal -Name "task-answer-question: attachment name preserved" `
        -Expected 'notes.md' `
        -Actual @($savedTask.questions_resolved)[0].attachments[0].name

    # Missing task_id should throw
    $threw = $false
    try {
        Invoke-TaskAnswerQuestion -Arguments @{ answer = 'A' }
    } catch {
        $threw = $true
    }

    Assert-True -Name "task-answer-question: missing task_id throws" `
        -Condition $threw `
        -Message "Expected throw for missing task_id"

} finally {
    $analysingDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\analysing"
    Remove-Item (Join-Path $analysingDir "$testTaskId.json") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $analysingDir "$testTaskId2.json") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $needsInputDir "$testTaskId.json") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $needsInputDir "$testTaskId2.json") -Force -ErrorAction SilentlyContinue
}

$allPassed = Write-TestSummary -LayerName "task-answer-question"
if (-not $allPassed) { exit 1 }
