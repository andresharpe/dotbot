<#
.SYNOPSIS
Post-script execution helper shared between the task-runner and kickstart engines.

.DESCRIPTION
Resolves a `post_script` path (relative to the bot root) and invokes it with the
standard parameter set used by both the task-runner (Invoke-WorkflowProcess) and
the kickstart engine (Invoke-KickstartProcess). Raises on non-zero exit code so
callers can decide how to handle failure.

Path resolution rules:
  - "scripts/..."         -> resolved relative to $BotRoot
  - anything else         -> resolved relative to $BotRoot/systems/runtime/

Forward- or back-slashes in the raw path are normalised so the resolved path is
valid on both Windows and Unix.
#>

function Invoke-PostScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$ProcessId,
        [Parameter(Mandatory)][string]$RawPostScript
    )

    # NOTE: post_script is trusted manifest input (developer-authored, checked in).
    # Normalise backslashes to forward slashes so Join-Path produces a valid
    # path on both Windows and Unix (Windows accepts either separator).
    $normalized = $RawPostScript -replace '\\', '/'

    $postPath = if ($normalized -match '^scripts/') {
        Join-Path $BotRoot $normalized
    } else {
        Join-Path $BotRoot "systems/runtime/$normalized"
    }

    if (-not (Test-Path $postPath)) {
        throw "post_script not found: $postPath"
    }

    Write-Status "Running post-script: $RawPostScript" -Type Process
    Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Executing post_script: $RawPostScript"

    $global:LASTEXITCODE = 0
    & $postPath -BotRoot $BotRoot -ProductDir $ProductDir -Settings $Settings -Model $Model -ProcessId $ProcessId
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "post_script exited with code $LASTEXITCODE"
    }
}

<#
.SYNOPSIS
Escalate a post_script failure by moving a task from done/ → needs-input/.

.DESCRIPTION
Used by the Claude-executed branch in Invoke-WorkflowProcess.ps1 when a
post_script fails after `task_mark_done` has already moved the task JSON into
`workspace\tasks\done\`. Rather than destroy the worktree and increment failure
counters, we move the task to `workspace\tasks\needs-input\` with a
`pending_question` so the operator can inspect the worktree, fix the post_script
(or the artefacts it consumes), and retry manually.

Mirrors the merge-conflict escalation pattern already used when the squash-merge
step fails. Returns $true if the task was moved, $false otherwise (e.g. the task
JSON was not found in done/).
#>
function Invoke-PostScriptFailureEscalation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$TasksBaseDir,
        [Parameter(Mandatory)][string]$PostScriptError,
        [AllowEmptyString()][string]$WorktreePath = ""
    )

    $doneDir = Join-Path $TasksBaseDir "done"
    $needsInputDir = Join-Path $TasksBaseDir "needs-input"

    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }

    $taskFile = Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
        try {
            $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $c.id -eq $Task.id
        } catch { $false }
    } | Select-Object -First 1

    if (-not $taskFile) { return $false }

    $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
    $nowIso = (Get-Date).ToUniversalTime().ToString("o")

    # Use Add-Member -Force so the helper works on task JSON that may or may not
    # already have status / updated_at / pending_question properties.
    $taskContent | Add-Member -NotePropertyName 'status' -NotePropertyValue 'needs-input' -Force
    $taskContent | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue $nowIso -Force

    if (-not $taskContent.PSObject.Properties['pending_question']) {
        $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
    }

    $contextText = if ($WorktreePath) {
        "Error: $PostScriptError. Worktree preserved at: $WorktreePath"
    } else {
        "Error: $PostScriptError"
    }

    $taskContent.pending_question = @{
        id             = "post-script-failure"
        question       = "post_script failed during task completion"
        context        = $contextText
        options        = @(
            @{ key = "A"; label = "Fix the post_script and retry manually"; rationale = "Inspect the worktree, repair the post_script, then retry the task" }
            @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
        )
        recommendation = "A"
        asked_at       = (Get-Date).ToUniversalTime().ToString("o")
    }

    $newPath = Join-Path $needsInputDir $taskFile.Name
    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newPath -Encoding UTF8
    Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue

    return $true
}

<#
.SYNOPSIS
Task-runner wrapper that invokes a task's post_script (if any) and reports failure.

.DESCRIPTION
Used by both task-runner code paths in Invoke-WorkflowProcess.ps1 to avoid
duplicating the guard + try/catch + logging block. Returns $null on success or
when the task has no post_script; returns a string error message on failure,
leaving it to the caller to flip any success flag.
#>
function Invoke-TaskPostScriptIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$ProcessId
    )

    if (-not $Task.post_script) { return $null }

    try {
        Invoke-PostScript -BotRoot $BotRoot -ProductDir $ProductDir -Settings $Settings `
            -Model $Model -ProcessId $ProcessId -RawPostScript $Task.post_script
        return $null
    } catch {
        $msg = "post_script failed: $($_.Exception.Message)"
        Write-Status $msg -Type Error
        Write-ProcessActivity -Id $ProcessId -ActivityType "error" -Message "$($Task.name): $msg"
        return $msg
    }
}
