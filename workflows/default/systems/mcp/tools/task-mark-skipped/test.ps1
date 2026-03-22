# Tests for task_mark_skipped

# Source the script
. "$PSScriptRoot\script.ps1"

# Test data
$testTaskId = "test-skip-task-$(Get-Random)"
$testTask = @{
    id = $testTaskId
    name = "Test Skip Task"
    status = "in-progress"
    category = "test"
    priority = 50
    description = "Task for testing skip functionality"
    acceptance_criteria = @("Test criterion 1")
    steps = @("Test step 1")
    created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

# Setup test environment
$tasksBaseDir = Join-Path $PSScriptRoot "..\\..\\..\\tasks"
$inProgressDir = Join-Path $tasksBaseDir "in-progress"
$skippedDir = Join-Path $tasksBaseDir "skipped"

# Ensure directories exist
New-Item -ItemType Directory -Force -Path $inProgressDir | Out-Null

# Create test task in in-progress
$testTaskFile = Join-Path $inProgressDir "$testTaskId.json"
$testTask | ConvertTo-Json -Depth 10 | Set-Content -Path $testTaskFile -Encoding UTF8

Write-Host "Testing task_mark_skipped..."

# Test 1: Mark task as skipped with non-recoverable reason
Write-Host "`nTest 1: Mark task as skipped (non-recoverable)"
$result = Invoke-TaskMarkSkipped -Arguments @{
    task_id = $testTaskId
    skip_reason = "non-recoverable"
}

if ($result.success) {
    Write-Host "✓ Task marked as skipped" -ForegroundColor Green
    Write-Host "  - Old status: $($result.old_status)"
    Write-Host "  - New status: $($result.new_status)"
    Write-Host "  - Skip reason: $($result.skip_reason)"
    Write-Host "  - Skip count: $($result.skip_count)"
} else {
    Write-Host "✗ Failed to mark task as skipped" -ForegroundColor Red
}

# Test 2: Verify skip_history was created
Write-Host "`nTest 2: Verify skip_history array"
$skippedFile = Join-Path $skippedDir "$testTaskId.json"
if (Test-Path $skippedFile) {
    $content = Get-Content $skippedFile -Raw | ConvertFrom-Json
    if ($content.skip_history -and $content.skip_history.Count -eq 1) {
        Write-Host "✓ skip_history array created with 1 entry" -ForegroundColor Green
        Write-Host "  - Reason: $($content.skip_history[0].reason)"
        Write-Host "  - Timestamp: $($content.skip_history[0].skipped_at)"
    } else {
        Write-Host "✗ skip_history not properly created" -ForegroundColor Red
    }
} else {
    Write-Host "✗ Task file not found in skipped directory" -ForegroundColor Red
}

# Test 3: Mark same task as skipped again (should append to history)
Write-Host "`nTest 3: Mark same task as skipped again (append to history)"
$result2 = Invoke-TaskMarkSkipped -Arguments @{
    task_id = $testTaskId
    skip_reason = "max-retries"
}

if ($result2.success -and $result2.skip_count -eq 2) {
    Write-Host "✓ Second skip appended to history" -ForegroundColor Green
    Write-Host "  - Skip count: $($result2.skip_count)"
} else {
    Write-Host "✗ Failed to append to skip_history" -ForegroundColor Red
}

# Test 4: Verify both entries in skip_history
Write-Host "`nTest 4: Verify both skip_history entries"
if (Test-Path $skippedFile) {
    $content = Get-Content $skippedFile -Raw | ConvertFrom-Json
    if ($content.skip_history.Count -eq 2) {
        Write-Host "✓ Both skip entries present" -ForegroundColor Green
        for ($i = 0; $i -lt $content.skip_history.Count; $i++) {
            $entry = $content.skip_history[$i]
            Write-Host "  - Skip $($i + 1): $($entry.reason) at $($entry.skipped_at)"
        }
    } else {
        Write-Host "✗ Expected 2 skip entries, found $($content.skip_history.Count)" -ForegroundColor Red
    }
} else {
    Write-Host "✗ Skipped file not found" -ForegroundColor Red
}

# Cleanup
Write-Host "`nCleaning up test files..."
Remove-Item -Path $skippedFile -Force -ErrorAction SilentlyContinue
Write-Host "Test complete."
