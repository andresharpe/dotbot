function Invoke-DecisionGet {
    param([hashtable]$Arguments)

    $decId = $Arguments['decision_id']
    if (-not $decId) { throw "decision_id is required" }
    if ($decId -notmatch '^dec-[a-f0-9]{8}$') { throw "Invalid decision_id format '$decId'. Expected: dec-XXXXXXXX" }

    # Decisions are dotbot state in the MAIN repo (issue #515). The MCP server
    # resolves the main root into $global:DotbotBotRoot; prefer it so decisions read
    # or written from a linked worktree still target main (matching the runtime-
    # backed task tools + dashboard). Fall back to the cwd walk when it is unset.
    $stateBotRoot = if ((Test-Path Variable:global:DotbotBotRoot) -and $global:DotbotBotRoot) { $global:DotbotBotRoot } else { Get-DotbotProjectBotPath }

    $decisionsBaseDir = Join-Path $stateBotRoot "workspace" "decisions"
    $allStatuses = @('proposed', 'accepted', 'deprecated', 'superseded')

    $found = $null
    foreach ($statusDir in $allStatuses) {
        $dirPath = Join-Path $decisionsBaseDir $statusDir
        if (-not (Test-Path $dirPath)) { continue }
        $files = @(Get-ChildItem -LiteralPath $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$decId-*.json" -or $_.Name -eq "$decId.json" })
        if ($files.Count -gt 0) {
            $found = @{ file = $files[0]; status = $statusDir }
            break
        }
    }

    if (-not $found) { throw "Decision '$decId' not found" }

    $dec = Get-Content -Path $found.file.FullName -Raw | ConvertFrom-Json

    # Audit: record which decision a task read during execution. Gives a
    # per-task trail of which decisions (incl. inbound funnel ones) actually
    # reached and were consumed by the agent. task id comes from the harness
    # env, set on the executing task-runner.
    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        $currentTaskId = $env:DOTBOT_CURRENT_TASK_ID
        $tagStr = if ($dec.tags) { (@($dec.tags) -join ',') } else { '' }
        Write-BotLog -Level Info -Message "decision_get: task '$currentTaskId' read $($dec.id) '$($dec.title)' [tags: $tagStr]" `
            -Context @{ activity_type = 'decision_read'; decision_id = "$($dec.id)"; task_id = "$currentTaskId"; tags = $tagStr }
    }

    return @{
        success = $true
        id = $dec.id
        title = $dec.title
        type = $dec.type
        status = $found.status
        date = $dec.date
        context = $dec.context
        decision = $dec.decision
        consequences = $dec.consequences
        alternatives_considered = $dec.alternatives_considered
        stakeholders = $dec.stakeholders
        related_task_ids = $dec.related_task_ids
        related_decision_ids = $dec.related_decision_ids
        supersedes = $dec.supersedes
        superseded_by = $dec.superseded_by
        tags = $dec.tags
        impact = $dec.impact
        deprecation_reason = $dec.deprecation_reason
        file_path = $found.file.FullName
    }
}
