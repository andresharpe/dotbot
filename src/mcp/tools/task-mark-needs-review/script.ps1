function Invoke-TaskMarkNeedsReview {
    param([hashtable]$Arguments)

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }
    $reason = $Arguments['reason']

    # Read current task state
    $resp = Invoke-McpRuntimeRequest -Method GET -Path "/tasks/$taskId"
    if (-not $resp) { throw "Task '$taskId' not found" }

    # Idempotent: already parked for review
    if ([string]$resp.status -eq 'needs-review') {
        return @{
            success    = $true
            message    = "Task is already in needs-review status"
            task_id    = $taskId
            old_status = 'needs-review'
            new_status = 'needs-review'
        }
    }

    # Require in-progress source state
    if ([string]$resp.status -ne 'in-progress') {
        return @{ success = $false; error = "Task '$taskId' is in status '$($resp.status)', not in-progress; refusing to park for review" }
    }

    # Require extensions.review.required === true (the per-task opt-in flag)
    $reviewExt = $null
    if ($resp.extensions -and $resp.extensions.PSObject.Properties['review']) {
        $reviewExt = $resp.extensions.review
    }
    $required = $false
    if ($reviewExt -and $reviewExt.PSObject.Properties['required']) {
        $required = [bool]$reviewExt.required
    }
    if (-not $required) {
        return @{ success = $false; error = "Task '$taskId' does not have extensions.review.required=true; refusing to park for review" }
    }

    # Capture pending commit SHA so the reject path knows what to discard.
    # Worktree map lookup is best-effort — a task without a worktree (skip_worktree)
    # is still allowed to park, just without a pending_commit reference.
    $pendingCommit = $null
    try {
        if (-not (Get-Module Dotbot.Worktree)) {
            $candidates = @(
                (Join-Path $global:DotbotProjectRoot ".bot/src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1"),
                (Join-Path $env:DOTBOT_HOME "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1")
            )
            foreach ($c in $candidates) {
                if ($c -and (Test-Path $c)) {
                    Import-Module $c -DisableNameChecking -Global -ErrorAction SilentlyContinue
                    break
                }
            }
        }
        if (Get-Command Get-TaskWorktreeInfo -ErrorAction SilentlyContinue) {
            $info = Get-TaskWorktreeInfo -TaskId $taskId -BotRoot $global:DotbotBotRoot
            if ($info -and $info.worktree_path -and (Test-Path $info.worktree_path)) {
                $sha = git -C $info.worktree_path rev-parse HEAD 2>$null
                if ($LASTEXITCODE -eq 0) { $pendingCommit = $sha.Trim() }
            }
        }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Could not capture review commit SHA for task $taskId" -Exception $_
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # PATCH extensions.review with the review payload (deep-merged by the runtime)
    $reviewPatch = @{
        status       = 'pending'
        requested_at = $now
    }
    if ($pendingCommit) { $reviewPatch['pending_commit'] = $pendingCommit }
    if ($reason)        { $reviewPatch['request_reason'] = $reason }

    $null = Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body @{
        actor      = Get-McpActor
        extensions = @{ review = $reviewPatch }
    }

    # Transition status
    $statusBody = @{ to = 'needs-review'; actor = Get-McpActor }
    if ($reason) { $statusBody['reason'] = $reason }
    $null = Invoke-McpRuntimeRequest -Method POST -Path "/tasks/$taskId/status" -Body $statusBody

    return @{
        success        = $true
        message        = "Task parked for human review"
        task_id        = $taskId
        task_name      = [string]$resp.name
        old_status     = 'in-progress'
        new_status     = 'needs-review'
        pending_commit = $pendingCommit
    }
}
