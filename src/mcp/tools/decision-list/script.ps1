function Invoke-DecisionList {
    param([hashtable]$Arguments)

    $filterStatus = $Arguments['status']
    # Decisions are dotbot state in the MAIN repo (issue #515). The MCP server
    # resolves the main root into $global:DotbotBotRoot; prefer it so decisions read
    # or written from a linked worktree still target main (matching the runtime-
    # backed task tools + dashboard). Fall back to the cwd walk when it is unset.
    $stateBotRoot = if ((Test-Path Variable:global:DotbotBotRoot) -and $global:DotbotBotRoot) { $global:DotbotBotRoot } else { Get-DotbotProjectBotPath }
    $decisionsBaseDir = Join-Path $stateBotRoot "workspace" "decisions"
    $allStatuses = @('proposed', 'accepted', 'deprecated', 'superseded')

    if ($filterStatus -and $filterStatus -notin $allStatuses) {
        throw "Invalid status filter '$filterStatus'. Must be one of: $($allStatuses -join ', ')"
    }

    $searchDirs = if ($filterStatus) { @($filterStatus) } else { $allStatuses }

    $decisions = @()
    foreach ($statusDir in $searchDirs) {
        $dirPath = Join-Path $decisionsBaseDir $statusDir
        if (-not (Test-Path $dirPath)) { continue }

        $files = Get-ChildItem -Path $dirPath -Filter "dec-*.json" -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $dec = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                $decisions += @{
                    id = $dec.id
                    title = $dec.title
                    type = $dec.type
                    status = $statusDir
                    date = $dec.date
                    impact = $dec.impact
                    tags = $dec.tags
                    superseded_by = $dec.superseded_by
                    file_path = $file.FullName
                    file_name = $file.Name
                }
            } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        }
    }

    $decisions = @($decisions | Sort-Object { $_.id })

    # Audit: record the decision scan a task performed during execution -- which
    # decisions were surfaced to the agent (incl. inbound funnel ones) and the
    # status filter used. Pairs with the per-decision decision_read log.
    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        $currentTaskId = $env:DOTBOT_CURRENT_TASK_ID
        $ids = (@($decisions | ForEach-Object { $_.id })) -join ','
        Write-BotLog -Level Info -Message "decision_list: task '$currentTaskId' status='$filterStatus' surfaced $($decisions.Count) decision(s): $ids" `
            -Context @{ activity_type = 'decision_list'; task_id = "$currentTaskId"; count = $decisions.Count; filter = "$filterStatus" }
    }

    return @{
        success = $true
        count = $decisions.Count
        decisions = $decisions
    }
}
