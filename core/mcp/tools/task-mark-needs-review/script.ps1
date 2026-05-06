Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force

function Invoke-TaskMarkNeedsReview {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    $projectRoot = $global:DotbotProjectRoot
    if (-not $projectRoot) { throw "Project root not available. MCP server may not have initialized correctly." }

    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('in-progress')
    if (-not $found) {
        throw "Task with ID '$taskId' not found in in-progress status"
    }

    if ($found.Content.needs_review -ne $true) {
        throw "Task '$taskId' does not have needs_review=true; refusing to park for review"
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

    $result = Set-TaskState -TaskId $taskId `
        -FromStates @('in-progress') `
        -ToState 'needs-review' `
        -Updates $updates

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
