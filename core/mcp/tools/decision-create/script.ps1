function Invoke-DecisionCreate {
    param([hashtable]$Arguments)

    $title = $Arguments['title']
    $type = $Arguments['type'] ?? 'technical'
    $context = $Arguments['context']
    $decision = $Arguments['decision']
    $consequences = $Arguments['consequences'] ?? ''
    $alternativesRaw = $Arguments['alternatives_considered'] ?? @()
    $stakeholders = $Arguments['stakeholders'] ?? @()
    $relatedTaskIds = $Arguments['related_task_ids'] ?? @()
    $relatedDecisionIds = $Arguments['related_decision_ids'] ?? @()
    $tags = $Arguments['tags'] ?? @()
    $impact = $Arguments['impact'] ?? 'medium'
    $status = $Arguments['status'] ?? 'proposed'

    if (-not $title) { throw "title is required" }
    if (-not $context) { throw "context is required" }
    if (-not $decision) { throw "decision is required" }

    $validStatuses = @('proposed', 'accepted')
    if ($status -notin $validStatuses) { throw "Invalid status '$status'. Must be one of: $($validStatuses -join ', ')" }

    $validTypes = @('architecture', 'business', 'technical', 'process')
    if ($type -notin $validTypes) { throw "Invalid type '$type'. Must be one of: $($validTypes -join ', ')" }

    $validImpacts = @('high', 'medium', 'low')
    if ($impact -notin $validImpacts) { throw "Invalid impact '$impact'. Must be one of: $($validImpacts -join ', ')" }

    # Validate related_decision_ids format
    $relatedDecisionIds = @($relatedDecisionIds | Where-Object { $_ -match '^dec-[a-f0-9]{8}$' })

    # Ensure alternatives is array of objects
    $alternatives = @()
    foreach ($alt in $alternativesRaw) {
        if ($alt -is [hashtable] -or $alt -is [PSCustomObject]) {
            $alternatives += $alt
        }
    }

    $id = "dec-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    $slug = ($title -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).TrimEnd('-') }

    $decisionsBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\decisions"
    $targetDir = Join-Path $decisionsBaseDir $status
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

    $dec = @{
        id = $id
        title = $title
        type = $type
        status = $status
        date = $date
        context = $context
        decision = $decision
        consequences = $consequences
        alternatives_considered = $alternatives
        stakeholders = @($stakeholders)
        related_task_ids = @($relatedTaskIds)
        related_decision_ids = $relatedDecisionIds
        supersedes = $null
        superseded_by = $null
        tags = @($tags)
        impact = $impact
        deprecation_reason = $null
    }

    $fileName = "$id-$slug.json"
    $filePath = Join-Path $targetDir $fileName
    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8

    return @{
        success = $true
        decision_id = $id
        status = $status
        file_path = $filePath
        message = "Decision '$title' created as $id ($status)"
    }
}
