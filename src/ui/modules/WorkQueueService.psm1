<#
.SYNOPSIS
Work queue service skeleton for fleet task dispatch (Phase 10 / Drone).

.DESCRIPTION
Provides a file-based work queue that the Mothership uses to dispatch tasks to
registered drone runtimes. Storage mirrors FleetAPI.psm1: JSON files under
fleet/queue/<RuntimeId>/.

This is a skeleton — function signatures are stable and importable by #96
(Drone agent), but full dispatch logic is deferred to the Drone phase.
#>

$script:QueueConfig = @{
    ControlDir = $null
}

function Initialize-WorkQueueService {
    <#
    .SYNOPSIS
        Sets up the work queue storage directory. Call once at server startup.
    #>
    param(
        [Parameter(Mandatory)][string]$ControlDir
    )
    $script:QueueConfig.ControlDir = $ControlDir
    $queueRoot = _Get-QueueRoot
    if (-not (Test-Path -LiteralPath $queueRoot)) {
        New-Item -ItemType Directory -Path $queueRoot -Force | Out-Null
    }
}

function Enqueue-WorkItem {
    <#
    .SYNOPSIS
        Adds a work item to a runtime's queue.
    .PARAMETER RuntimeId
        The target runtime that should process this item.
    .PARAMETER TaskId
        The task ID to dispatch.
    .PARAMETER Payload
        Arbitrary hashtable of additional context (workflow name, run id, etc.).
    .OUTPUTS
        Hashtable with the new item's id and queued_at timestamp.
    #>
    param(
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][string]$TaskId,
        [hashtable]$Payload = @{}
    )

    $itemId  = "wqi-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $item    = [ordered]@{
        id         = $itemId
        runtime_id = $RuntimeId
        task_id    = $TaskId
        payload    = $Payload
        status     = 'pending'
        queued_at  = (Get-Date).ToUniversalTime().ToString('o')
    }

    $dir = _Get-RuntimeQueueDir -RuntimeId $RuntimeId
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    _Write-QueueJson -Path (Join-Path $dir "$itemId.json") -Value $item

    return @{ id = $itemId; queued_at = $item.queued_at }
}

function Dequeue-WorkItem {
    <#
    .SYNOPSIS
        Pops the next pending work item for a runtime (FIFO by queued_at).
        Marks the item as 'leased' so it is not returned again.
        Returns $null when the queue is empty.
    #>
    param(
        [Parameter(Mandatory)][string]$RuntimeId
    )

    $dir = _Get-RuntimeQueueDir -RuntimeId $RuntimeId
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
               Sort-Object Name)

    foreach ($file in $files) {
        $item = _Read-QueueJson -Path $file.FullName
        if (-not $item -or $item['status'] -ne 'pending') { continue }

        $item['status']    = 'leased'
        $item['leased_at'] = (Get-Date).ToUniversalTime().ToString('o')
        _Write-QueueJson -Path $file.FullName -Value $item

        return [ordered]@{
            id         = $item['id']
            runtime_id = $item['runtime_id']
            task_id    = $item['task_id']
            payload    = $item['payload']
            queued_at  = $item['queued_at']
            leased_at  = $item['leased_at']
        }
    }

    return $null
}

function Get-WorkQueueDepth {
    <#
    .SYNOPSIS
        Returns the count of pending (not yet leased) items for a runtime.
    #>
    param(
        [Parameter(Mandatory)][string]$RuntimeId
    )

    $dir = _Get-RuntimeQueueDir -RuntimeId $RuntimeId
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $item = _Read-QueueJson -Path $file.FullName
        if ($item -and $item['status'] -eq 'pending') { $count++ }
    }
    return $count
}

function Complete-WorkItem {
    <#
    .SYNOPSIS
        Marks a leased work item as completed. Called by the drone after finishing.
    #>
    param(
        [Parameter(Mandatory)][string]$RuntimeId,
        [Parameter(Mandatory)][string]$ItemId
    )

    $path = Join-Path (_Get-RuntimeQueueDir -RuntimeId $RuntimeId) "$ItemId.json"
    $item = _Read-QueueJson -Path $path
    if (-not $item) { return @{ success = $false; error = 'item not found' } }

    $item['status']       = 'completed'
    $item['completed_at'] = (Get-Date).ToUniversalTime().ToString('o')
    _Write-QueueJson -Path $path -Value $item

    return @{ success = $true }
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function _Get-QueueRoot {
    return Join-Path $script:QueueConfig.ControlDir 'fleet' 'queue'
}

function _Get-RuntimeQueueDir {
    param([Parameter(Mandatory)][string]$RuntimeId)
    $safe = $RuntimeId -replace '[^A-Za-z0-9_.-]', '_'
    return Join-Path (_Get-QueueRoot) $safe
}

function _Read-QueueJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } catch { return $null }
}

function _Write-QueueJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

Export-ModuleMember -Function @(
    'Initialize-WorkQueueService',
    'Enqueue-WorkItem',
    'Dequeue-WorkItem',
    'Get-WorkQueueDepth',
    'Complete-WorkItem'
)
