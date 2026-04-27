function Invoke-DecisionGet {
    param([hashtable]$Arguments)

    $decId = $Arguments['decision_id']
    if (-not $decId) { throw "decision_id is required" }
    if ($decId -notmatch '^dec-[a-f0-9]{8}$') { throw "Invalid decision_id format '$decId'. Expected: dec-XXXXXXXX" }

    $decisionsBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\decisions"
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
