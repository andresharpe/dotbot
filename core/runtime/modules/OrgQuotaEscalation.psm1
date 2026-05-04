<#
.SYNOPSIS
    Shared helper for parking a task in needs-input/ when the provider returns
    a non-resettable org/monthly usage quota event (#391).

.DESCRIPTION
    The org-quota wording ("You've hit your org's monthly usage limit") is
    classified as kind='org_quota' by Get-RateLimitClassification. Unlike a
    transient rate-limit, waiting will not unblock the task — admin/billing
    action is required. This helper consolidates the analyse-phase and
    execute-phase escalation paths so both write the same pending_question
    shape and surface the same source-of-truth.
#>

function Move-TaskToOrgQuotaNeedsInput {
    <#
    .SYNOPSIS
    Move a task from $SourceDir to needs-input/ with a provider-org-quota
    pending_question. Returns a result hashtable; never throws on file ops.

    .PARAMETER SourceDir
    Directory under $TasksBaseDir to look in. 'analysing' for the analyse
    phase, 'in-progress' for the execute phase.

    .PARAMETER WorktreePath
    Optional. When supplied, the worktree path is appended to the
    pending_question.context so the operator knows the worktree is retained.

    .OUTPUTS
    @{ success; new_path; source_status; reason }
    success=$false sets reason and leaves files untouched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TaskId,
        [Parameter(Mandatory)] [string] $TasksBaseDir,
        [Parameter(Mandatory)] [ValidateSet('analysing', 'in-progress')] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $RateLimitMessage,
        [string] $WorktreePath
    )

    $sourcePath = Join-Path $TasksBaseDir $SourceDir
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return @{ success = $false; new_path = $null; source_status = $null; reason = "Source dir missing: $sourcePath" }
    }

    $taskFile = Get-ChildItem -LiteralPath $sourcePath -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $TaskId } catch { $false }
    } | Select-Object -First 1

    if (-not $taskFile) {
        return @{ success = $false; new_path = $null; source_status = $SourceDir; reason = "Task $TaskId not found in $SourceDir/" }
    }

    $needsInputDir = Join-Path $TasksBaseDir "needs-input"
    if (-not (Test-Path -LiteralPath $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }

    $taskData = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
    $nowIso = (Get-Date).ToUniversalTime().ToString("o")
    $taskData | Add-Member -NotePropertyName status -NotePropertyValue 'needs-input' -Force
    $taskData | Add-Member -NotePropertyName updated_at -NotePropertyValue $nowIso -Force

    $context = "Provider quota: $RateLimitMessage"
    if ($WorktreePath) { $context += ". Worktree retained at: $WorktreePath" }

    $taskData | Add-Member -NotePropertyName pending_question -NotePropertyValue @{
        id             = "provider-org-quota"
        question       = "Provider org/monthly usage quota exhausted — admin or billing action required before resume"
        context        = $context
        options        = @(
            @{ key = "A"; label = "Wait for quota and resume"; rationale = "Admin tops up the org or waits for the next billing cycle, then move the task back to todo" }
            @{ key = "B"; label = "Skip this task"; rationale = "Mark the task skipped and continue once quota returns" }
        )
        recommendation = "A"
        asked_at       = $nowIso
    } -Force

    $newPath = Join-Path $needsInputDir $taskFile.Name
    $taskData | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $newPath -Encoding UTF8
    try {
        Remove-Item -LiteralPath $taskFile.FullName -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
        return @{ success = $false; new_path = $null; source_status = $SourceDir; reason = "Failed to remove source file: $($_.Exception.Message)" }
    }

    return @{ success = $true; new_path = $newPath; source_status = $SourceDir; reason = $null }
}

Export-ModuleMember -Function 'Move-TaskToOrgQuotaNeedsInput'
