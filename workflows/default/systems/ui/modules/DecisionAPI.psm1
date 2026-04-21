<#
.SYNOPSIS
Decision Record API module

.DESCRIPTION
Provides decision listing, retrieval, creation, status transitions, and updates.
Decisions are stored as JSON files in status-based subdirectories.
#>

$script:Config = @{
    BotRoot = $null
}

function Initialize-DecisionAPI {
    param(
        [Parameter(Mandatory)] [string]$BotRoot
    )
    $script:Config.BotRoot = $BotRoot
}

function Get-DecisionsBaseDir {
    return (Join-Path $script:Config.BotRoot "workspace\decisions")
}

function Test-DecisionIdFormat([string]$Id) {
    return $Id -match '^dec-[a-f0-9]{8}$'
}

function Assert-ValidRelatedDecisions {
    param([array]$Items)
    $valid = @()
    foreach ($item in $Items) {
        if ($item -and $item -match '^dec-[a-f0-9]{8}$') {
            $valid += $item
        }
    }
    return $valid
}

function Find-DecisionFile {
    param([string]$DecisionId, [string[]]$Statuses)
    if (-not (Test-DecisionIdFormat $DecisionId)) { return $null }
    $base = Get-DecisionsBaseDir
    foreach ($s in $Statuses) {
        $dir = Join-Path $base $s
        if (-not (Test-Path $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$DecisionId-*.json" -or $_.Name -eq "$DecisionId.json" }
        if ($files.Count -gt 0) { return @{ file = @($files)[0]; status = $s } }
    }
    return $null
}

# ── List ──────────────────────────────────────────────────────────────────────

function Get-DecisionList {
    param([string]$StatusFilter)
    $base        = Get-DecisionsBaseDir
    $allStatuses = @('proposed', 'accepted', 'deprecated', 'superseded')
    if ($StatusFilter -and $StatusFilter -notin $allStatuses) {
        return @{ _statusCode = 400; success = $false; error = "Invalid status filter '$StatusFilter'. Must be one of: $($allStatuses -join ', ')" }
    }
    $searchDirs = if ($StatusFilter) { @($StatusFilter) } else { $allStatuses }
    $decisions  = @()

    foreach ($s in $searchDirs) {
        $dir = Join-Path $base $s
        if (-not (Test-Path $dir)) { continue }
        $files = Get-ChildItem -Path $dir -Filter "dec-*.json" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            try {
                $dec = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                $decisions += @{
                    id                  = $dec.id
                    title               = $dec.title
                    type                = $dec.type
                    status              = $dec.status
                    date                = $dec.date
                    impact              = $dec.impact
                    stakeholders        = @($dec.stakeholders)
                    tags                = @($dec.tags)
                    superseded_by       = $dec.superseded_by
                    related_decision_ids = @($dec.related_decision_ids)
                    file_name           = $f.Name
                }
            } catch { Write-BotLog -Level Debug -Message "Decision operation failed" -Exception $_ }
        }
    }

    $decisions = @($decisions | Sort-Object { $_.id })
    return @{ success = $true; count = $decisions.Count; decisions = $decisions }
}

# ── Get ───────────────────────────────────────────────────────────────────────

function Get-DecisionDetail {
    param([string]$DecisionId)
    $found = Find-DecisionFile -DecisionId $DecisionId -Statuses @('proposed', 'accepted', 'deprecated', 'superseded')
    if (-not $found) { return @{ _statusCode = 404; success = $false; error = "Decision '$DecisionId' not found" } }

    $dec = Get-Content -Path $found.file.FullName -Raw | ConvertFrom-Json
    $result = @{ success = $true }
    foreach ($prop in $dec.PSObject.Properties) {
        $result[$prop.Name] = $prop.Value
    }
    return $result
}

# ── Create ────────────────────────────────────────────────────────────────────

function New-Decision {
    param([hashtable]$Body)

    $title   = $Body['title']
    $context = $Body['context']
    $decisionText = $Body['decision']

    if (-not $title -or -not $context -or -not $decisionText) {
        return @{ _statusCode = 400; success = $false; error = "title, context, and decision are required" }
    }

    $type   = $Body['type'] ?? 'technical'
    $status = $Body['status'] ?? 'proposed'
    $impact = $Body['impact'] ?? 'medium'

    $validTypes    = @('architecture', 'business', 'technical', 'process')
    $validStatuses = @('proposed', 'accepted')
    $validImpacts  = @('high', 'medium', 'low')

    if ($type -notin $validTypes) {
        return @{ _statusCode = 400; success = $false; error = "type must be one of: $($validTypes -join ', ')" }
    }
    if ($status -notin $validStatuses) {
        return @{ _statusCode = 400; success = $false; error = "status must be proposed or accepted" }
    }
    if ($impact -notin $validImpacts) {
        return @{ _statusCode = 400; success = $false; error = "impact must be one of: $($validImpacts -join ', ')" }
    }

    $id   = "dec-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $slug = ($title -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).TrimEnd('-') }
    $date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    $stakeholders       = @($Body['stakeholders'] | Where-Object { $_ })
    $tags               = @($Body['tags'] | Where-Object { $_ })
    $relatedTaskIds     = @($Body['related_task_ids'] | Where-Object { $_ })
    $relatedDecisionIds = Assert-ValidRelatedDecisions @($Body['related_decision_ids'] | Where-Object { $_ })

    $alternatives = @()
    if ($Body['alternatives_considered']) {
        foreach ($alt in $Body['alternatives_considered']) {
            if ($alt -is [hashtable] -or $alt -is [System.Collections.IDictionary]) {
                $alternatives += @{ option = "$($alt['option'])"; reason_rejected = "$($alt['reason_rejected'])" }
            } elseif ($alt.PSObject -and $alt.option) {
                $alternatives += @{ option = "$($alt.option)"; reason_rejected = "$($alt.reason_rejected)" }
            }
        }
    }

    $dec = [ordered]@{
        id                      = $id
        title                   = $title
        type                    = $type
        status                  = $status
        date                    = $date
        context                 = $context
        decision                = $decisionText
        consequences            = $Body['consequences'] ?? ''
        alternatives_considered = $alternatives
        stakeholders            = $stakeholders
        related_task_ids        = $relatedTaskIds
        related_decision_ids    = $relatedDecisionIds
        supersedes              = $null
        superseded_by           = $null
        tags                    = $tags
        impact                  = $impact
        deprecation_reason      = $null
    }

    $targetDir = Join-Path (Get-DecisionsBaseDir) $status
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    $filePath = Join-Path $targetDir "$id-$slug.json"
    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8

    return @{ success = $true; decision_id = $id; status = $status; file_path = $filePath; message = "Decision '$title' created as $id" }
}

# ── Update ────────────────────────────────────────────────────────────────────

function Update-Decision {
    param([string]$DecisionId, [hashtable]$Body)

    $found = Find-DecisionFile -DecisionId $DecisionId -Statuses @('proposed', 'accepted', 'deprecated', 'superseded')
    if (-not $found) { return @{ _statusCode = 404; success = $false; error = "Decision '$DecisionId' not found" } }

    $dec = Get-Content -Path $found.file.FullName -Raw | ConvertFrom-Json
    $dec.date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    $stringFields = @('title', 'context', 'decision', 'consequences', 'type', 'impact')
    foreach ($field in $stringFields) {
        if ($Body.ContainsKey($field)) { $dec.$field = $Body[$field] }
    }

    $arrayFields = @('stakeholders', 'tags', 'related_task_ids')
    foreach ($field in $arrayFields) {
        if ($Body.ContainsKey($field)) { $dec.$field = @($Body[$field] | Where-Object { $_ }) }
    }

    if ($Body.ContainsKey('related_decision_ids')) {
        $dec.related_decision_ids = Assert-ValidRelatedDecisions @($Body['related_decision_ids'] | Where-Object { $_ })
    }

    if ($Body.ContainsKey('alternatives_considered')) {
        $alternatives = @()
        foreach ($alt in $Body['alternatives_considered']) {
            if ($alt -is [hashtable] -or $alt -is [System.Collections.IDictionary]) {
                $alternatives += @{ option = "$($alt['option'])"; reason_rejected = "$($alt['reason_rejected'])" }
            } elseif ($alt.PSObject -and $alt.option) {
                $alternatives += @{ option = "$($alt.option)"; reason_rejected = "$($alt.reason_rejected)" }
            }
        }
        $dec.alternatives_considered = $alternatives
    }

    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $found.file.FullName -Encoding UTF8

    return @{ success = $true; decision_id = $DecisionId; message = "Decision '$DecisionId' updated" }
}

# ── Status transitions ────────────────────────────────────────────────────────

function Set-DecisionStatus {
    param([string]$DecisionId, [string]$NewStatus, [string]$SupersededBy, [string]$Reason)

    $allStatuses = @('proposed', 'accepted', 'deprecated', 'superseded')
    if ($NewStatus -notin $allStatuses) {
        return @{ _statusCode = 400; success = $false; error = "Invalid status '$NewStatus'. Must be one of: $($allStatuses -join ', ')" }
    }
    if (-not (Test-DecisionIdFormat $DecisionId)) {
        return @{ _statusCode = 400; success = $false; error = "Invalid decision ID format '$DecisionId'. Expected: dec-XXXXXXXX" }
    }
    if ($NewStatus -eq 'superseded') {
        if (-not $SupersededBy) {
            return @{ _statusCode = 400; success = $false; error = "superseded_by is required when transitioning to superseded" }
        }
        if (-not (Test-DecisionIdFormat $SupersededBy)) {
            return @{ _statusCode = 400; success = $false; error = "Invalid superseded_by format '$SupersededBy'. Expected: dec-XXXXXXXX" }
        }
    }

    $validSources = @('proposed', 'accepted')
    $found = Find-DecisionFile -DecisionId $DecisionId -Statuses $validSources
    if (-not $found) {
        $existing = Find-DecisionFile -DecisionId $DecisionId -Statuses @($NewStatus)
        if ($existing) { return @{ success = $true; decision_id = $DecisionId; message = "Decision '$DecisionId' is already $NewStatus" } }
        return @{ _statusCode = 404; success = $false; error = "Decision '$DecisionId' not found in proposed or accepted" }
    }

    # Idempotency
    if ($found.status -eq $NewStatus) {
        return @{ success = $true; decision_id = $DecisionId; status = $NewStatus; file_path = $found.file.FullName; message = "Decision '$DecisionId' is already $NewStatus" }
    }

    $dec = Get-Content -Path $found.file.FullName -Raw | ConvertFrom-Json
    $dec.status = $NewStatus
    $dec.date   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    if ($NewStatus -eq 'superseded' -and $SupersededBy) {
        $dec.superseded_by = $SupersededBy
        # Also update the superseding decision's 'supersedes' field
        $supersedesFound = Find-DecisionFile -DecisionId $SupersededBy -Statuses $allStatuses
        if ($supersedesFound) {
            $superDec = Get-Content -Path $supersedesFound.file.FullName -Raw | ConvertFrom-Json
            $superDec.supersedes = $DecisionId
            $superDec | ConvertTo-Json -Depth 10 | Set-Content -Path $supersedesFound.file.FullName -Encoding UTF8
        }
    }

    if ($NewStatus -eq 'deprecated' -and $Reason) {
        $dec.deprecation_reason = $Reason
    }

    $base      = Get-DecisionsBaseDir
    $targetDir = Join-Path $base $NewStatus
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    $targetPath = Join-Path $targetDir $found.file.Name
    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Encoding UTF8
    Remove-Item -Path $found.file.FullName -Force

    return @{ success = $true; decision_id = $DecisionId; status = $NewStatus; file_path = $targetPath; message = "Decision '$DecisionId' is now $NewStatus" }
}

Export-ModuleMember -Function @(
    'Initialize-DecisionAPI',
    'Get-DecisionList',
    'Get-DecisionDetail',
    'New-Decision',
    'Update-Decision',
    'Set-DecisionStatus'
)
