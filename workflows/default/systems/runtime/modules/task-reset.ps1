<#
.SYNOPSIS
Task reset utilities for autonomous task management

.DESCRIPTION
Provides functions for resetting in-progress and skipped tasks back to todo status
#>

function Reset-InProgressTasks {
    <#
    .SYNOPSIS
    Reset all in-progress tasks to todo status
    
    .PARAMETER TasksBaseDir
    Base directory containing task subdirectories (todo, in-progress, done)
    
    .OUTPUTS
    Array of hashtables with reset task information
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TasksBaseDir
    )
    
    $resetTasks = @()
    $inProgressDir = Join-Path $TasksBaseDir "in-progress"
    
    if (-not (Test-Path $inProgressDir)) {
        return $resetTasks
    }
    
    $inProgressTasks = @(Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
    
    if ($inProgressTasks.Count -eq 0) {
        return $resetTasks
    }
    
    foreach ($taskFile in $inProgressTasks) {
        try {
            # Re-verify file exists (may have been moved by concurrent process)
            if (-not (Test-Path $taskFile.FullName)) { continue }

            $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
            $taskId = $taskContent.id
            $taskName = $taskContent.name

            # Check if this task was already completed — if so, just delete the orphan
            $doneFile = Join-Path $TasksBaseDir "done" $taskFile.Name
            if (Test-Path $doneFile) {
                Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            # If task has analysis data, return to analysed; otherwise to todo
            $hasAnalysis = $taskContent.analysis -and $taskContent.analysis.PSObject.Properties.Count -gt 0
            if ($hasAnalysis) {
                $targetDir = Join-Path $TasksBaseDir "analysed"
                $targetStatus = "analysed"
            } else {
                $targetDir = Join-Path $TasksBaseDir "todo"
                $targetStatus = "todo"
            }

            # Ensure target directory exists
            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }

            $targetPath = Join-Path $targetDir $taskFile.Name

            # Update status
            $taskContent.status = $targetStatus
            $taskContent.started_at = $null
            $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Write to target directory
            $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Force

            # Remove from in-progress (ignore if already gone — concurrent process handled it)
            Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue
            
            $resetTasks += @{
                id = $taskId
                name = $taskName
                file = $taskFile.Name
            }
        } catch {
            Write-BotLog -Level Warn -Message "Error processing task: $($taskFile.Name)" -Exception $_
        }
    }
    
    return $resetTasks
}

function Reset-SkippedTasks {
    <#
    .SYNOPSIS
    Reset all skipped tasks to todo status
    
    .PARAMETER TasksBaseDir
    Base directory containing task subdirectories (todo, in-progress, skipped, done)
    
    .OUTPUTS
    Array of hashtables with reset task information
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TasksBaseDir
    )
    
    $resetTasks = @()
    $skippedDir = Join-Path $TasksBaseDir "skipped"
    
    if (-not (Test-Path $skippedDir)) {
        return $resetTasks
    }
    
    $skippedTasks = @(Get-ChildItem -Path $skippedDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
    
    if ($skippedTasks.Count -eq 0) {
        return $resetTasks
    }
    
    foreach ($taskFile in $skippedTasks) {
        try {
            # Re-verify file exists (may have been moved by concurrent process)
            if (-not (Test-Path $taskFile.FullName)) { continue }

            $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
            $taskId = $taskContent.id
            $taskName = $taskContent.name

            # Guard against infinite skip loops — leave persistently-failing tasks for manual review
            $skipCount = ($taskContent.skip_history | Measure-Object).Count
            if ($skipCount -ge 3) {
                Write-BotLog -Level Warn -Message "Task '$taskName' skipped $skipCount times - leaving in skipped for manual review"
                continue
            }

            # Check if this task was already completed — if so, just delete the orphan
            $doneFile = Join-Path $TasksBaseDir "done" $taskFile.Name
            if (Test-Path $doneFile) {
                Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            # Move to todo directory
            $todoDir = Join-Path $TasksBaseDir "todo"
            $todoPath = Join-Path $todoDir $taskFile.Name

            # Update status
            $taskContent.status = "todo"
            $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Preserve skip_history as audit trail
            # (don't clear it - this is intentional to maintain history for debugging)

            # Write to todo directory
            $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $todoPath -Force

            # Remove from skipped (ignore if already gone — concurrent process handled it)
            Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue
            
            $resetTasks += @{
                id = $taskId
                name = $taskName
                file = $taskFile.Name
                skip_count = ($taskContent.skip_history | Measure-Object).Count
            }
        } catch {
            Write-BotLog -Level Warn -Message "Error processing skipped task: $($taskFile.Name)" -Exception $_
        }
    }

    return $resetTasks
}

function Reset-AnalysingTasks {
    <#
    .SYNOPSIS
    Reset orphaned analysing tasks back to todo status

    .DESCRIPTION
    Cross-references tasks in analysing/ against live processes in the process registry.
    A task is considered orphaned if no running/starting process owns it AND its updated_at
    is older than 5 minutes (safety buffer to avoid racing with freshly launched processes).

    .PARAMETER TasksBaseDir
    Base directory containing task subdirectories (todo, analysing, etc.)

    .PARAMETER ProcessesDir
    Directory containing process registry JSON files

    .OUTPUTS
    Array of hashtables with recovered task information
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TasksBaseDir,

        [Parameter(Mandatory = $true)]
        [string]$ProcessesDir
    )

    $resetTasks = @()
    $analysingDir = Join-Path $TasksBaseDir "analysing"

    if (-not (Test-Path $analysingDir)) {
        return $resetTasks
    }

    $analysingTasks = @(Get-ChildItem -Path $analysingDir -Filter "*.json" -File -ErrorAction SilentlyContinue)

    if ($analysingTasks.Count -eq 0) {
        return $resetTasks
    }

    # Build set of task IDs owned by LIVE processes
    $liveTaskIds = [System.Collections.Generic.HashSet[string]]::new()

    if (Test-Path $ProcessesDir) {
        $processFiles = Get-ChildItem -Path $ProcessesDir -Filter "*.json" -File -ErrorAction SilentlyContinue

        foreach ($procFile in $processFiles) {
            try {
                $proc = Get-Content -Path $procFile.FullName -Raw | ConvertFrom-Json

                # Only consider running or starting processes
                if ($proc.status -notin @('running', 'starting')) { continue }

                # Verify the PID is actually alive
                $isAlive = $false
                if ($proc.pid) {
                    try {
                        Get-Process -Id $proc.pid -ErrorAction Stop | Out-Null
                        $isAlive = $true
                    } catch {
                        # PID not found - process is dead
                    }
                }

                if ($isAlive -and $proc.task_id) {
                    [void]$liveTaskIds.Add($proc.task_id)
                }
            } catch {
                # Skip malformed process files
            }
        }
    }

    $now = (Get-Date).ToUniversalTime()
    $stalenessThreshold = $now.AddMinutes(-5)

    foreach ($taskFile in $analysingTasks) {
        try {
            # Re-verify file exists (may have been moved by concurrent process)
            if (-not (Test-Path $taskFile.FullName)) { continue }

            $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
            $taskId = $taskContent.id
            $taskName = $taskContent.name

            # Skip if a live process owns this task
            if ($liveTaskIds.Contains($taskId)) { continue }

            # Safety buffer: skip if updated_at is less than 5 minutes ago
            if ($taskContent.updated_at) {
                # ConvertFrom-Json auto-parses ISO dates to DateTime; avoid double-parsing
                # which mangles month/day order across cultures
                $updatedAt = if ($taskContent.updated_at -is [datetime]) {
                    $taskContent.updated_at.ToUniversalTime()
                } else {
                    [DateTimeOffset]::Parse($taskContent.updated_at).UtcDateTime
                }
                if ($updatedAt -gt $stalenessThreshold) { continue }
            }

            # Check if this task was already completed — if so, just delete the orphan
            $doneFile = Join-Path $TasksBaseDir "done" $taskFile.Name
            if (Test-Path $doneFile) {
                Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue
                continue
            }

            # This task is orphaned and not yet done - recover it to todo
            $todoDir = Join-Path $TasksBaseDir "todo"
            if (-not (Test-Path $todoDir)) {
                New-Item -ItemType Directory -Path $todoDir -Force | Out-Null
            }
            $todoPath = Join-Path $todoDir $taskFile.Name

            # Update status and timestamps
            $taskContent.status = "todo"
            $taskContent.updated_at = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")

            # Clear analysis_started_at
            if ($taskContent.PSObject.Properties['analysis_started_at']) {
                $taskContent.analysis_started_at = $null
            }

            # Close any open analysis session (no ended_at)
            if ($taskContent.analysis_sessions) {
                foreach ($session in $taskContent.analysis_sessions) {
                    if ($session.PSObject.Properties['ended_at'] -and -not $session.ended_at) {
                        $session.ended_at = $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    } elseif (-not $session.PSObject.Properties['ended_at']) {
                        $session | Add-Member -NotePropertyName 'ended_at' -NotePropertyValue $now.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    }
                }
            }

            # Preserve analysis_sessions, questions_resolved, skip_history for audit

            # Write to todo directory
            $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $todoPath -Force

            # Remove from analysing (ignore if already gone — concurrent process handled it)
            Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue

            $resetTasks += @{
                id   = $taskId
                name = $taskName
                file = $taskFile.Name
            }
        } catch {
            Write-BotLog -Level Warn -Message "Error processing analysing task: $($taskFile.Name)" -Exception $_
        }
    }

    return $resetTasks
}
