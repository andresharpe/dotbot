<#
.SYNOPSIS
Atomic, lock-protected, retry-aware mutations for task JSON files.

.DESCRIPTION
Every create/update/move/delete of a task JSON file under
.bot/workspace/tasks/<state>/*.json must go through one of the helpers in
this module. Direct Set-Content / Out-File / Remove-Item / Move-Item calls
on those paths are forbidden (enforced by Test-Structure.ps1's
"Task file mutation hygiene" check).

Guarantees:

  - Writes are atomic. The new content is serialised to a temp file in
    the SAME directory as the target, then renamed over the target.
    rename(2) on POSIX and ReplaceFile on Windows are atomic so a crash
    mid-write leaves either the old file intact or the new file complete,
    never a truncated half-written JSON.

  - Cross-state moves are atomic-then-cleanup. Move-TaskFileAtomic writes
    the new file FIRST and removes the source second. A crash between
    those two steps leaves a duplicate (visible to the next index scan
    and easy to detect) rather than losing the task entirely.

  - Concurrent mutations of the same task id (e.g. the runtime worker and
    an MCP tool driven from the UI) are serialised by an OS-level
    exclusive lock on .bot/.control/task-locks/<task-id>.lock. Readers
    do not lock — atomic writes mean a reader sees either the old or new
    file in full, never a partial one.

  - Transient I/O errors (AV scanners, brief file-handle holds, NFS
    hiccups) are retried with exponential backoff before the failure is
    surfaced.
#>

# Retry policy for transient I/O failures.
$script:MaxRetries = 5
$script:BaseDelayMs = 25

function Get-TaskLockDirectory {
    param([string]$BotRoot)

    if (-not $BotRoot) {
        if (Get-Command Get-DotbotProjectBotPath -ErrorAction SilentlyContinue) {
            $BotRoot = Get-DotbotProjectBotPath
        } else {
            $cursor = $PSScriptRoot
            while ($cursor) {
                if ((Split-Path -Leaf $cursor) -eq '.bot') {
                    $BotRoot = $cursor
                    break
                }
                $parent = Split-Path -Parent $cursor
                if (-not $parent -or $parent -eq $cursor) { break }
                $cursor = $parent
            }
        }
    }

    if (-not $BotRoot) {
        throw "TaskFile: unable to resolve BotRoot for lock directory"
    }

    $dir = Join-Path $BotRoot ".control" "task-locks"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$Operation = 'task-file'
    )

    $attempt = 0
    while ($true) {
        try {
            return & $Action
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $attempt++
            if ($attempt -ge $script:MaxRetries) { throw }
            $delay = [int]($script:BaseDelayMs * [Math]::Pow(2, $attempt - 1))
            Start-Sleep -Milliseconds $delay
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message "[TaskFile] retry $attempt for $Operation ($($_.Exception.GetType().Name))"
            }
        }
    }
}

function Invoke-WithTaskLock {
    <#
    .SYNOPSIS
    Runs an action while holding an exclusive cross-process lock on a task id.
    #>
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$BotRoot,
        [int]$TimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return & $Action
    }

    $lockDir = Get-TaskLockDirectory -BotRoot $BotRoot
    $safeId = $TaskId -replace '[^a-zA-Z0-9_.-]', '_'
    $lockPath = Join-Path $lockDir "$safeId.lock"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stream = $null

    while ($null -eq $stream) {
        try {
            $stream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -gt $deadline) {
                throw "TaskFile: timed out after $TimeoutSeconds s waiting for lock on task '$TaskId' (lockfile: $lockPath)"
            }
            Start-Sleep -Milliseconds 25
        }
    }

    try {
        return & $Action
    } finally {
        $stream.Close()
        $stream.Dispose()
    }
}

function Write-TaskFileAtomic {
    <#
    .SYNOPSIS
    Atomically writes a task record to a single path.

    .PARAMETER Path
    Absolute target path for the JSON file.

    .PARAMETER Content
    Object serialised to JSON via ConvertTo-Json.

    .PARAMETER Depth
    ConvertTo-Json -Depth. Default 20.

    .PARAMETER TaskId
    Optional task id for the per-task lock. Pass an empty string for
    unique-path writes (e.g. archive records) that can never collide.
    #>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Content,
        [int]$Depth = 20,
        [string]$TaskId,
        [string]$BotRoot
    )

    $targetDir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $action = {
        $tmpPath = Join-Path $targetDir (
            '.' + [IO.Path]::GetFileName($Path) + '.tmp.' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        )
        try {
            Invoke-WithRetry -Operation "write-tmp $Path" -Action {
                $Content | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $tmpPath -Encoding UTF8
            }
            Invoke-WithRetry -Operation "rename $Path" -Action {
                Move-Item -LiteralPath $tmpPath -Destination $Path -Force
            }
        } finally {
            if (Test-Path -LiteralPath $tmpPath) {
                Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($TaskId) {
        Invoke-WithTaskLock -TaskId $TaskId -BotRoot $BotRoot -Action $action
    } else {
        & $action
    }
}

function Move-TaskFileAtomic {
    <#
    .SYNOPSIS
    Atomically moves a task to a new state directory with updated content.

    .DESCRIPTION
    Writes the new content to the target path atomically first, then removes
    the source. A crash between the two steps leaves a duplicate that the
    next index scan can detect; the alternative (rolling back the new write)
    would leave the task in a state visible to other readers as already moved.
    #>
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [Parameter(Mandatory)] $Content,
        [int]$Depth = 20,
        [string]$TaskId,
        [string]$BotRoot
    )

    $sourceFull = [IO.Path]::GetFullPath($SourcePath)
    $targetFull = [IO.Path]::GetFullPath($TargetPath)

    $action = {
        if ($sourceFull -eq $targetFull) {
            Write-TaskFileAtomic -Path $TargetPath -Content $Content -Depth $Depth -BotRoot $BotRoot
            return
        }

        Write-TaskFileAtomic -Path $TargetPath -Content $Content -Depth $Depth -BotRoot $BotRoot
        Invoke-WithRetry -Operation "delete-source $SourcePath" -Action {
            if (Test-Path -LiteralPath $SourcePath) {
                Remove-Item -LiteralPath $SourcePath -Force
            }
        }
    }

    if ($TaskId) {
        Invoke-WithTaskLock -TaskId $TaskId -BotRoot $BotRoot -Action $action
    } else {
        & $action
    }
}

function Remove-TaskFileAtomic {
    <#
    .SYNOPSIS
    Retry-aware delete of a task JSON file under the per-task lock.
    #>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string]$TaskId,
        [string]$BotRoot
    )

    $action = {
        Invoke-WithRetry -Operation "delete $Path" -Action {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force
            }
        }
    }

    if ($TaskId) {
        Invoke-WithTaskLock -TaskId $TaskId -BotRoot $BotRoot -Action $action
    } else {
        & $action
    }
}

Export-ModuleMember -Function @(
    'Write-TaskFileAtomic',
    'Move-TaskFileAtomic',
    'Remove-TaskFileAtomic',
    'Invoke-WithTaskLock'
)
