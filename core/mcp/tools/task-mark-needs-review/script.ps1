

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

if (-not (Get-Module TaskStore)) {
    Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -DisableNameChecking -Global
}
if (-not (Get-Module SessionTracking)) {
    Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/SessionTracking.psm1") -DisableNameChecking -Global
}

function Invoke-TaskMarkNeedsReview {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $reason = $Arguments['reason']
    if (-not $taskId) { throw "Task ID is required" }

    $projectRoot = $global:DotbotProjectRoot
    if (-not $projectRoot) { throw "Project root not available. MCP server may not have initialized correctly." }

    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('in-progress', 'needs-review')
    if (-not $found) {
        throw "Task with ID '$taskId' not found in in-progress or needs-review status"
    }

    if (($found.Content.PSObject.Properties['needs_review'] ? $found.Content.needs_review : $null) -ne $true) {
        throw "Task '$taskId' does not have needs_review=true; refusing to park for review"
    }

    # Idempotent: already parked — return success without re-running transitions
    if ($found.Status -eq 'needs-review') {
        return @{
            success               = $true
            message               = "Task is already in needs-review status"
            task_id               = $taskId
            task_name             = $found.Content.name
            old_status            = 'needs-review'
            new_status            = 'needs-review'
            pending_review_commit = ($found.Content.PSObject.Properties['pending_review_commit'] ? $found.Content.pending_review_commit : $null)
            file_path             = $found.File.FullName
        }
    }

    # Capture current commit SHA on the task branch so the reject path knows what to discard
    $pendingReviewCommit = $null
    try {
        $botRoot = Join-Path $projectRoot ".bot"
        $mapPath = Join-Path $botRoot ".control\worktree-map.json"
        if (Test-Path $mapPath) {
            $map = Get-Content $mapPath -Raw | ConvertFrom-Json
            $entry = $map.PSObject.Properties[$taskId]
            if ($entry -and $entry.Value.worktree_path) {
                $worktreePath = $entry.Value.worktree_path
                $sha = git -C $worktreePath rev-parse HEAD 2>$null
                if ($LASTEXITCODE -eq 0) { $pendingReviewCommit = $sha.Trim() }
            }
        }
    } catch {
        Write-BotLog -Level Debug -Message "Could not capture review commit SHA for task $taskId" -Exception $_
    }

    $updates = @{
        review_status          = 'pending'
        pending_review_commit  = $pendingReviewCommit
        review_requested_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    if ($reason) { $updates['review_request_reason'] = $reason }

    $result = Set-TaskState -TaskId $taskId `
        -FromStates @('in-progress') `
        -ToState 'needs-review' `
        -Updates $updates

    # Close the execution session so session history reflects the phase boundary
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $result.task_content -SessionId $claudeSessionId -Phase 'execution'
        $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
    }

    return @{
        success                = $true
        message                = "Task parked for human review"
        task_id                = $taskId
        task_name              = $result.task_content.name
        old_status             = $result.old_status
        new_status             = 'needs-review'
        pending_review_commit  = $pendingReviewCommit
        file_path              = $result.file_path
    }
}
