function Invoke-DecisionUpdate {
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

    # Update date
    $dec.date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    # Apply field updates
    if ($Arguments.ContainsKey('title'))        { $dec.title = $Arguments['title'] }
    if ($Arguments.ContainsKey('type')) {
        $validTypes = @('architecture', 'business', 'technical', 'process')
        if ($Arguments['type'] -notin $validTypes) { throw "Invalid type '$($Arguments['type'])'" }
        $dec.type = $Arguments['type']
    }
    if ($Arguments.ContainsKey('context'))      { $dec.context = $Arguments['context'] }
    if ($Arguments.ContainsKey('decision'))     { $dec.decision = $Arguments['decision'] }
    if ($Arguments.ContainsKey('consequences')) { $dec.consequences = $Arguments['consequences'] }
    if ($Arguments.ContainsKey('impact')) {
        $validImpacts = @('high', 'medium', 'low')
        if ($Arguments['impact'] -notin $validImpacts) { throw "Invalid impact '$($Arguments['impact'])'" }
        $dec.impact = $Arguments['impact']
    }
    if ($Arguments.ContainsKey('alternatives_considered')) {
        $alts = @()
        foreach ($alt in $Arguments['alternatives_considered']) {
            if ($alt -is [hashtable] -or $alt -is [PSCustomObject]) { $alts += $alt }
        }
        $dec.alternatives_considered = $alts
    }
    if ($Arguments.ContainsKey('stakeholders'))         { $dec.stakeholders = @($Arguments['stakeholders']) }
    if ($Arguments.ContainsKey('related_task_ids'))      { $dec.related_task_ids = @($Arguments['related_task_ids']) }
    if ($Arguments.ContainsKey('related_decision_ids')) {
        $dec.related_decision_ids = @($Arguments['related_decision_ids'] | Where-Object { $_ -match '^dec-[a-f0-9]{8}$' })
    }
    if ($Arguments.ContainsKey('tags')) { $dec.tags = @($Arguments['tags']) }

    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $found.file.FullName -Encoding UTF8

    return @{
        success = $true
        decision_id = $decId
        message = "Decision '$decId' updated"
        file_path = $found.file.FullName
    }
}
