<#
.SYNOPSIS
Single point for managing dotbot decision records.

.DESCRIPTION
This module owns everything about writing a decision record:

1. New-DecisionRecord -- the write primitive. The ONLY code that generates a
   record: id/slug/date generation, status/type/impact validation, the record
   shape (including the optional external_ref provenance block), and the write
   under <project>/.bot/workspace/decisions/<status>/. Both the MCP
   decision_create tool (the AI-agent path) and the inbound funnel call it; no
   one else re-implements generation.

2. New-InboundDecision -- the inbound funnel. Promotes external events
   (mothership answers, workflow registry changes, material settings changes)
   to decision records. It owns ONLY mapping (event -> decision fields) and
   dedup (idempotency key + cache + committed-record scan); it never generates
   a record itself -- it calls New-DecisionRecord. Best-effort: a failure is
   logged via Write-BotLog and never rethrown to the primary action.

Dotbot.Core (paths) and Dotbot.Settings (merged state) are imported globally by
Private/Imports.ps1. Callers may override the .bot path via -BotPath, which is
how tests target a temp directory.
#>

#region Write primitive

function New-DecisionRecord {
    <#
    .SYNOPSIS
    Generate and persist a decision record. The single decision-write primitive.

    .PARAMETER Arguments
    Hashtable of decision fields. Recognised keys: title (required), context
    (required), decision (required), type, consequences, alternatives_considered,
    stakeholders, related_task_ids, related_decision_ids, tags, impact, status,
    external_ref (@{ source; key; raw }).

    .PARAMETER BotPath
    Optional override of the project .bot path. Defaults to
    Get-DotbotProjectBotPath. Used by tests to target a temp directory.

    .OUTPUTS
    Hashtable: @{ success; decision_id; status; file_path; message }.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Arguments,
        [string]$BotPath
    )

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
    $externalRef = $Arguments['external_ref']

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

    # Decisions are dotbot state and live in the MAIN repo (issue #515). The MCP
    # server resolves that main root into $global:DotbotBotRoot; prefer it so a
    # decision written from a linked worktree still lands in main (matching the
    # runtime-backed task tools and the dashboard). Fall back to the cwd walk when
    # the global is unset (e.g. tests). An explicit -BotPath always wins.
    $botPathResolved = if ($BotPath) { $BotPath } elseif ($global:DotbotBotRoot) { $global:DotbotBotRoot } else { Get-DotbotProjectBotPath }
    $decisionsBaseDir = Join-Path $botPathResolved "workspace" "decisions"
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
        external_ref = $externalRef
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

#endregion

#region Inbound funnel

# The material settings allow-list. Per-key: only these settings produce a
# decision record; every other key (costs.*, editor.*, logging.*, the
# non-enabled mothership.* connection keys, etc.) is intentionally skipped.
# This is the only place the settings vocabulary lives (issue #416, Q1).
$script:InboundSettingsAllowList = @(
    'provider'
    'analysis.model'
    'execution.model'
    'analysis.auto_approve_splits'
    'analysis.mode'
    'file_listener.watchers'
    'mothership.enabled'
)

function Get-InboundDedupDir {
    param([Parameter(Mandatory)][string]$BotPath)
    return (Join-Path $BotPath ".control" "decisions-inbound")
}

function Get-InboundKeyHash {
    # Stable filename for an idempotency key. The key may contain '/', ':', and
    # other path-unsafe characters, so the cache file is named by hash and the
    # full key is stored inside it.
    param([Parameter(Mandatory)][string]$Key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key))) -replace '-', ''
    } finally {
        $sha.Dispose()
    }
    return $hash.Substring(0, 32).ToLowerInvariant()
}

function Test-InboundDuplicate {
    <#
    .SYNOPSIS
    Returns $true if a record with this idempotency key already exists.

    .DESCRIPTION
    Fast path: a cache file under .control/decisions-inbound/. Durable fallback
    (fresh clone, empty cache): scan committed records' external_ref.key. The
    committed records are the source of truth; the cache is only a fast path.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$BotPath
    )

    $cacheFile = Join-Path (Get-InboundDedupDir -BotPath $BotPath) ((Get-InboundKeyHash -Key $Key) + ".json")
    if (Test-Path $cacheFile) { return $true }

    $decisionsDir = Join-Path $BotPath "workspace" "decisions"
    if (-not (Test-Path $decisionsDir)) { return $false }

    foreach ($file in (Get-ChildItem -Path $decisionsDir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ($record.PSObject.Properties['external_ref'] -and $record.external_ref -and
            $record.external_ref.PSObject.Properties['key'] -and "$($record.external_ref.key)" -eq $Key) {
            return $true
        }
    }

    return $false
}

function Write-InboundDedupCache {
    <#
    .SYNOPSIS
    Record that an inbound key has been processed. Atomic create; never throws.

    .DESCRIPTION
    Uses FileMode.CreateNew (atomic, fails if the file already exists) mirroring
    Request-ProcessLock in Dotbot.Process -- two concurrent runs that race past
    the dedup check both attempt the create; the loser's IOException is swallowed.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$DecisionId,
        [Parameter(Mandatory)][string]$BotPath
    )

    $dir = Get-InboundDedupDir -BotPath $BotPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cacheFile = Join-Path $dir ((Get-InboundKeyHash -Key $Key) + ".json")

    $payload = @{ key = $Key; decision_id = $DecisionId; written_at = (Get-Date).ToUniversalTime().ToString("o") } |
        ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    try {
        $fs = [System.IO.File]::Open($cacheFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            $fs.Close()
        }
    } catch [System.IO.IOException] {
        # Another run created the cache file first -- harmless.
    }
}

function ConvertTo-InboundMothershipFields {
    # Mothership answer -> decision fields. One answer shape across both hook
    # sites (issue #416 correction 2). Type mapping is the rigid Q8 table.
    param([Parameter(Mandatory)][hashtable]$Payload)

    $questionType = "$($Payload['questionType'])"
    $answer = "$($Payload['answer'])"
    $questionText = if ($Payload['questionText']) { "$($Payload['questionText'])" } else { $null }
    $questionId = "$($Payload['questionId'])"
    $taskId = "$($Payload['taskId'])"
    $options = $Payload['options']
    $relatedTaskIds = if ($Payload['relatedTaskIds']) { @($Payload['relatedTaskIds']) } elseif ($taskId) { @($taskId) } else { @() }

    # The mothership answer for an option question is the bare option key (e.g.
    # "B"). A bare key is meaningless to the analysis/execution reader, so resolve
    # it against the question options to the "<key> - <label>" form (matching
    # Resolve-TaskInputAnswer) and carry the option rationale into consequences.
    # The pause-pattern question carries no explicit type; when options are
    # present treat it as a single-choice answer.
    $matched = Get-InboundOptionMatch -Options $options -Key $answer
    if (-not $questionType -and $matched) { $questionType = 'singleChoice' }

    $decisionText = if ($matched) { "$answer - $($matched.label)" } else { $answer }
    $consequences = if ($matched) { "$($matched.rationale)" } else { '' }

    $requiresReview = $false
    $type =
        switch ($questionType) {
            'approval'        { 'process' }
            'priorityRanking' { 'business' }
            'freeText'        { $requiresReview = $true; 'process' }
            'singleChoice'    { 'process' }
            default           { 'process' }
        }

    $status = if ($requiresReview) { 'proposed' } else { 'accepted' }
    $title = if ($questionText) { "Inbound answer: $questionText" } else { "Inbound answer for question $questionId" }
    $context = if ($questionText) {
        "Answer to '$questionText' received via mothership on task ${taskId}: $decisionText."
    } else {
        "Answer received via mothership for question $questionId on task ${taskId}: $decisionText."
    }

    return @{
        title = $title
        type = $type
        status = $status
        impact = 'medium'
        context = $context
        decision = $decisionText
        consequences = $consequences
        related_task_ids = $relatedTaskIds
        tags = @('inbound:mothership')
    }
}

function Get-InboundOptionMatch {
    # Resolve a bare option key (e.g. "B") against a question's options array to
    # the matching option's label + rationale. Options may be hashtables (tests)
    # or PSCustomObjects (task JSON). Returns $null when there is no single-key
    # match (approval / freeText / priorityRanking answers fall through).
    param($Options, [string]$Key)

    if (-not $Options -or [string]::IsNullOrWhiteSpace($Key)) { return $null }

    foreach ($opt in @($Options)) {
        if (-not $opt) { continue }
        $k = if ($opt -is [System.Collections.IDictionary]) { $opt['key'] }
             elseif ($opt.PSObject.Properties['key']) { $opt.key } else { $null }
        if ("$k" -ne "$Key") { continue }

        $label = if ($opt -is [System.Collections.IDictionary]) { $opt['label'] }
                 elseif ($opt.PSObject.Properties['label']) { $opt.label } else { $null }
        $rationale = if ($opt -is [System.Collections.IDictionary]) { $opt['rationale'] }
                     elseif ($opt.PSObject.Properties['rationale']) { $opt.rationale } else { $null }
        return @{ label = "$label"; rationale = "$rationale" }
    }
    return $null
}

function ConvertTo-InboundRegistryFields {
    # Workflow registry add/remove -> decision fields.
    param([Parameter(Mandatory)][hashtable]$Payload)

    $workflow = "$($Payload['workflow'])"
    $title = if ($Payload['title']) { "$($Payload['title'])" } else { "Workflow registry change: $workflow" }
    $action = "$($Payload['action'])"

    return @{
        title = $title
        type = 'process'
        status = 'accepted'
        impact = 'medium'
        context = "Workflow registry change ($action) for workflow '$workflow'."
        decision = $title
        tags = @('inbound:registry')
    }
}

function ConvertTo-InboundSettingsFields {
    # Material settings change -> decision fields. Returns $null for any key not
    # on the allow-list (the caller treats $null as "skip, no record").
    param([Parameter(Mandatory)][hashtable]$Payload)

    $key = "$($Payload['key'])"
    if ($key -notin $script:InboundSettingsAllowList) { return $null }

    $before = if ($Payload.ContainsKey('before')) { "$($Payload['before'])" } else { '' }
    $after = if ($Payload.ContainsKey('after')) { "$($Payload['after'])" } else { '' }

    # provider change and mothership enablement are the high-impact settings.
    $impact = if ($key -in @('provider', 'mothership.enabled')) { 'high' } else { 'medium' }

    return @{
        title = "Settings change: $key"
        type = 'process'
        status = 'accepted'
        impact = $impact
        context = "Setting '$key' changed from '$before' to '$after'."
        decision = "Set $key = $after"
        tags = @('inbound:settings')
    }
}

function Get-InboundIdempotencyKey {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][hashtable]$Payload
    )

    switch ($Source) {
        'mothership' {
            return "mothership:$($Payload['projectId'])/$($Payload['questionId'])/$($Payload['instanceId'])"
        }
        'registry' {
            return "registry:$($Payload['action']):$($Payload['namespace']):$($Payload['workflow'])"
        }
        'settings' {
            $key = "$($Payload['key'])"
            $before = if ($Payload.ContainsKey('before')) { "$($Payload['before'])" } else { '' }
            $after = if ($Payload.ContainsKey('after')) { "$($Payload['after'])" } else { '' }
            $hash = Get-InboundKeyHash -Key "$before|$after"
            return "settings:${key}:$hash"
        }
        default {
            return "${Source}:$([guid]::NewGuid().ToString('N'))"
        }
    }
}

function New-InboundDecision {
    <#
    .SYNOPSIS
    The inbound decision funnel. Promotes an external event to a decision record.

    .DESCRIPTION
    Owns mapping (event -> decision fields) and dedup (idempotency key + cache +
    committed-record scan) ONLY. Generation is delegated to New-DecisionRecord.
    Best-effort: any failure is logged via Write-BotLog and NOT rethrown, so the
    primary action (answer write-back, workflow add/remove, settings save) always
    completes (issue #416, Q3).

    .PARAMETER Source
    One of: mothership, registry, settings.

    .PARAMETER Payload
    Source-specific event data. See the ConvertTo-Inbound*Fields helpers and
    Get-InboundIdempotencyKey for the per-source key set.

    .PARAMETER BotPath
    Optional override of the project .bot path. Defaults to Get-DotbotProjectBotPath.

    .OUTPUTS
    The New-DecisionRecord result hashtable on write, or $null when skipped
    (duplicate, non-material settings key, or a swallowed failure).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('mothership', 'registry', 'settings')][string]$Source,
        [Parameter(Mandatory)][hashtable]$Payload,
        [string]$BotPath
    )

    try {
        # Decisions are dotbot state and live in the MAIN repo (issue #515). The MCP
    # server resolves that main root into $global:DotbotBotRoot; prefer it so a
    # decision written from a linked worktree still lands in main (matching the
    # runtime-backed task tools and the dashboard). Fall back to the cwd walk when
    # the global is unset (e.g. tests). An explicit -BotPath always wins.
    $botPathResolved = if ($BotPath) { $BotPath } elseif ($global:DotbotBotRoot) { $global:DotbotBotRoot } else { Get-DotbotProjectBotPath }

        $fields =
            switch ($Source) {
                'mothership' { ConvertTo-InboundMothershipFields -Payload $Payload }
                'registry'   { ConvertTo-InboundRegistryFields -Payload $Payload }
                'settings'   { ConvertTo-InboundSettingsFields -Payload $Payload }
            }

        # Settings funnel returns $null for non-material keys -- skip silently.
        if (-not $fields) { return $null }

        $key = Get-InboundIdempotencyKey -Source $Source -Payload $Payload

        if (Test-InboundDuplicate -Key $key -BotPath $botPathResolved) { return $null }

        $fields['external_ref'] = @{
            source = $Source
            key = $key
            raw = $Payload
        }

        $result = New-DecisionRecord -Arguments $fields -BotPath $botPathResolved

        if ($result -and $result.success) {
            Write-InboundDedupCache -Key $key -DecisionId $result.decision_id -BotPath $botPathResolved
        }

        return $result
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "Inbound decision funnel failed (source: $Source)" -Exception $_
        }
        return $null
    }
}

#endregion

Export-ModuleMember -Function @(
    'New-DecisionRecord'
    'New-InboundDecision'
)
