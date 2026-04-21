<#
.SYNOPSIS
File system listener that triggers task-creation when new files appear in configured workspace folders.

.DESCRIPTION
Monitors folders defined in settings.default.json under file_listener.watchers.
When a matching file is created or updated, launches a task-creation process
(91-new-tasks.md) with the file path as context so Claude can review the new
document against existing tasks and product docs and create appropriate tasks.

Architecture note: Each watcher runs its own dedicated worker runspace that owns
the FileSystemWatcher and calls WaitForChanged() in a loop. This avoids Register-ObjectEvent
entirely — no PS event system, no $script: scope issues, no silent failures.
#>

if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $PSScriptRoot "..\..\runtime\modules\SettingsLoader.psm1") -DisableNameChecking -Global
}

# Module-scope state
$script:Workers     = [System.Collections.Generic.List[hashtable]]::new()  # { PS; StopFlag; EventJob }
$script:Initialized = $false

function Initialize-InboxWatcher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BotRoot
    )

    if ($script:Initialized) {
        Write-BotLog -Level Debug -Message "[InboxWatcher] Already initialized, skipping"
        return
    }

    $workspaceRoot = Join-Path $BotRoot "workspace"

    # Resolve the three-tier settings chain and read file_listener from the merged result
    $settings = Get-MergedSettings -BotRoot $BotRoot
    if (-not $settings.PSObject.Properties['file_listener']) {
        Write-BotLog -Level Debug -Message "[InboxWatcher] No file_listener config found in merged settings"
        return
    }

    $listenerConfig = $settings.file_listener
    if (-not $listenerConfig -or $listenerConfig.enabled -ne $true) {
        Write-BotLog -Level Debug -Message "[InboxWatcher] File listener disabled or not configured"
        return
    }

    $watcherDefs = @($listenerConfig.watchers)
    if ($watcherDefs.Count -eq 0) {
        Write-BotLog -Level Debug -Message "[InboxWatcher] No watchers configured"
        return
    }

    $maxConcurrent = if (($listenerConfig.max_concurrent -as [int]) -gt 0) {
        $listenerConfig.max_concurrent -as [int]
    } else { 3 }

    $coalesceWindow = if (($listenerConfig.coalesce_window_seconds -as [int]) -gt 0) {
        $listenerConfig.coalesce_window_seconds -as [int]
    } else { 10 }

    $logPath    = Join-Path $BotRoot ".control" "logs" "inbox-watcher.log"
    $null       = New-Item -ItemType Directory -Force -Path (Split-Path $logPath -Parent)
    $resolvedRoot = [System.IO.Path]::GetFullPath($workspaceRoot)
    $rootPrefix   = $resolvedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    foreach ($watcherDef in $watcherDefs) {
        $folder = $watcherDef.folder
        if (-not $folder) {
            Write-BotLog -Level Warn -Message "[InboxWatcher] Watcher config missing 'folder' field, skipping"
            continue
        }

        # Reject rooted paths — on Windows, Join-Path with a rooted second argument
        # discards the base entirely, bypassing the workspace boundary.
        if ([System.IO.Path]::IsPathRooted($folder)) {
            Write-BotLog -Level Warn -Message "[InboxWatcher] Rooted folder path rejected, skipping: $folder"
            continue
        }

        # Normalise via GetFullPath so '..' sequences are resolved, then assert the
        # result is still inside $workspaceRoot before doing anything with it.
        $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $folder))

        if ($resolvedPath -ne $resolvedRoot -and -not $resolvedPath.StartsWith($rootPrefix)) {
            Write-BotLog -Level Warn -Message "[InboxWatcher] Folder '$folder' escapes workspace root, skipping: $resolvedPath"
            continue
        }

        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            Write-BotLog -Level Warn -Message "[InboxWatcher] Watched folder not found, skipping: $resolvedPath"
            continue
        }

        $filter      = if ($watcherDef.filter)      { $watcherDef.filter }      else { '*' }
        $events      = if ($watcherDef.events)      { @($watcherDef.events) }   else { @('created') }
        $folderLabel = if ($watcherDef.description) { $watcherDef.description } else { "watched folder ($folder)" }

        $knownEvents  = @('created', 'updated')
        $unknownEvents = @($events | Where-Object { $_ -notin $knownEvents })
        foreach ($unknown in $unknownEvents) {
            Write-BotLog -Level Warn -Message "[InboxWatcher] Unknown event type '$unknown' for $folder — did you mean 'created' or 'updated'?"
        }

        $watchCreated = 'created' -in $events
        $watchUpdated = 'updated' -in $events

        if (-not $watchCreated -and -not $watchUpdated) {
            Write-BotLog -Level Warn -Message "[InboxWatcher] No valid events configured for $folder, skipping"
            continue
        }

        # Each watcher gets its own runspace that owns the FileSystemWatcher and
        # calls WaitForChanged() — pure .NET, no Register-ObjectEvent, no scope issues.
        $workerRunspace = [runspacefactory]::CreateRunspace()
        $workerRunspace.Open()
        $workerRunspace.SessionStateProxy.SetVariable('WatchedPath',  $resolvedPath)
        $workerRunspace.SessionStateProxy.SetVariable('Filter',       $filter)
        $workerRunspace.SessionStateProxy.SetVariable('WatchCreated', $watchCreated)
        $workerRunspace.SessionStateProxy.SetVariable('WatchUpdated', $watchUpdated)
        $workerRunspace.SessionStateProxy.SetVariable('FolderLabel',  $folderLabel)
        $workerRunspace.SessionStateProxy.SetVariable('BotRoot',        $BotRoot)
        $workerRunspace.SessionStateProxy.SetVariable('LogPath',        $logPath)
        $workerRunspace.SessionStateProxy.SetVariable('MaxConcurrent',   $maxConcurrent)
        $workerRunspace.SessionStateProxy.SetVariable('CoalesceWindow', $coalesceWindow)
        # StopFlag is a single-element bool array so the worker runspace receives a
        # reference to the same .NET object, not a copy.  This works correctly for
        # standard (non-constrained) runspaces created via CreateRunspace() — variable
        # injection does not serialize for in-process runspaces.
        $stopFlag = [bool[]](,$false)
        $workerRunspace.SessionStateProxy.SetVariable('StopFlag',       $stopFlag)

        $ps = [powershell]::Create()
        $ps.Runspace = $workerRunspace
        $null = $ps.AddScript({
            function Write-WorkerLog {
                param(
                    [string]$Message,
                    [System.Management.Automation.ErrorRecord]$Exception
                )
                try {
                    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [InboxWatcher] $Message"
                    if ($Exception) {
                        $line += " | $($Exception.Exception.Message)"
                        if ($Exception.ScriptStackTrace) { $line += " at $($Exception.ScriptStackTrace)" }
                    }
                    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
                } catch {}
            }

            Write-WorkerLog "Worker started. Watching: $WatchedPath (filter: $Filter, coalesce: ${CoalesceWindow}s)"

            $watcher = New-Object System.IO.FileSystemWatcher
            $watcher.Path                  = $WatchedPath
            $watcher.Filter                = $Filter
            $watcher.NotifyFilter          = [System.IO.NotifyFilters]::LastWrite -bor
                                             [System.IO.NotifyFilters]::FileName  -bor
                                             [System.IO.NotifyFilters]::CreationTime
            $watcher.InternalBufferSize    = 65536
            $watcher.IncludeSubdirectories = $false
            # EnableRaisingEvents is not needed when using synchronous WaitForChanged().
            # Leaving it true just buffers events through the async mechanism unnecessarily.
            $watcher.EnableRaisingEvents   = $false

            $watchTypes = [System.IO.WatcherChangeTypes]::None
            if ($WatchCreated) { $watchTypes = $watchTypes -bor [System.IO.WatcherChangeTypes]::Created }
            if ($WatchUpdated) { $watchTypes = $watchTypes -bor [System.IO.WatcherChangeTypes]::Changed }

            $recentlyProcessed = @{}
            $runningProcs      = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
            $pendingFiles      = [System.Collections.Generic.List[hashtable]]::new()
            $lastEventTime     = [DateTime]::MinValue

            # $flushPending is a scriptblock rather than a named function so it can close
            # over $pendingFiles, $runningProcs, and the injected runspace variables without
            # threading them through an explicit parameter list.  It mutates $runningProcs
            # (prune exited + add new) but never touches $pendingFiles directly — the caller
            # always calls $pendingFiles.Clear() after invoking it.
            $flushPending = {
                if ($pendingFiles.Count -eq 0) { return }

                if ($pendingFiles.Count -eq 1) {
                    $entry         = $pendingFiles[0]
                    $contextPrompt = "A new file '$($entry.SafeName)' has been added to $FolderLabel (path: $($entry.Path)). Read this file using your available tools, review its contents against the existing product documentation and task list, and create any new tasks needed to address the changes, requirements, or decisions it represents."
                    $description   = "Review new file: $($entry.SafeName)"
                } else {
                    $fileList      = ($pendingFiles | ForEach-Object { "- $($_.SafeName) (path: $($_.Path))" }) -join "`n"
                    $contextPrompt = "$($pendingFiles.Count) new files have been added to $FolderLabel`:`n$fileList`n`nRead each file using your available tools, review their contents against the existing product documentation and task list, and create any new tasks needed."
                    $description   = "Review $($pendingFiles.Count) new files in $FolderLabel"
                }

                $launcherPath = Join-Path $BotRoot "systems" "runtime" "launch-process.ps1"
                if (-not (Test-Path -LiteralPath $launcherPath)) {
                    Write-WorkerLog "ERROR: Launcher not found at $launcherPath"
                    return
                }

                $null = $runningProcs.RemoveAll([Predicate[System.Diagnostics.Process]]{ param($p) $p.HasExited })
                if ($runningProcs.Count -ge $MaxConcurrent) {
                    Write-WorkerLog "Concurrency limit ($MaxConcurrent) reached, dropping batch of $($pendingFiles.Count) file(s)"
                    return
                }

                # Write the prompt to a temp file and invoke via a wrapper script so the
                # long prompt string never touches the command line — the same pattern
                # used by ProductAPI.psm1.  Passing -Prompt directly through
                # Start-Process -ArgumentList breaks on Windows because PS 7.x does not
                # reliably quote array elements that contain spaces.
                $launchersDir = Join-Path $BotRoot ".control" "launchers"
                $null         = New-Item -ItemType Directory -Force -Path $launchersDir -ErrorAction SilentlyContinue

                # Prune launcher pairs older than 1 hour to prevent unbounded growth.
                Get-ChildItem -Path $launchersDir -Filter "inbox-launcher-*.ps1" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt [DateTime]::Now.AddHours(-1) } |
                    ForEach-Object {
                        $s = $_.BaseName -replace '^inbox-launcher-', ''
                        Remove-Item (Join-Path $launchersDir "inbox-prompt-$s.txt") -Force -ErrorAction SilentlyContinue
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }

                $stamp        = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff")
                $promptFile   = Join-Path $launchersDir "inbox-prompt-$stamp.txt"
                $wrapperPath  = Join-Path $launchersDir "inbox-launcher-$stamp.ps1"

                $contextPrompt | Set-Content -LiteralPath $promptFile -Encoding UTF8 -NoNewline
                $escapedDesc = $description -replace "'", "''"
                @"
`$prompt = Get-Content -LiteralPath '$promptFile' -Raw
& '$launcherPath' -Type task-creation -Prompt `$prompt -Description '$escapedDesc'
"@ | Set-Content -LiteralPath $wrapperPath -Encoding UTF8

                $startParams = @{ ArgumentList = @("-NoProfile", "-File", $wrapperPath); PassThru = $true }
                if ($IsWindows) { $startParams.WindowStyle = 'Normal' }

                Write-WorkerLog "Launching task-creation for $($pendingFiles.Count) file(s): $(($pendingFiles | ForEach-Object { $_.SafeName }) -join ', ')"
                $proc = Start-Process pwsh @startParams
                if ($proc) { $runningProcs.Add($proc) }
                Write-WorkerLog "Launched: $description ($($runningProcs.Count)/$MaxConcurrent active)"
            }

            try {
                while (-not $StopFlag[0]) {
                    try {
                        $result = $watcher.WaitForChanged($watchTypes, 2000)
                        $now    = [DateTime]::UtcNow

                        if (-not $result.TimedOut) {
                            $filePath = Join-Path $WatchedPath $result.Name
                            Write-WorkerLog "File detected: $filePath"

                            if (Test-Path -LiteralPath $filePath -PathType Container) {
                                Write-WorkerLog "Skipping directory: $filePath"
                            } else {
                                $debounced = $recentlyProcessed.ContainsKey($filePath) -and
                                             ($now - $recentlyProcessed[$filePath]).TotalSeconds -lt 5
                                if ($debounced) {
                                    Write-WorkerLog "Debounced: $filePath"
                                } else {
                                    $recentlyProcessed[$filePath] = $now

                                    # Purge stale debounce entries (older than 60s).
                                    # This only runs on new file events, so the dictionary
                                    # retains entries indefinitely during idle periods — a
                                    # negligible memory leak in practice.
                                    $stale = @($recentlyProcessed.Keys | Where-Object {
                                        ($now - $recentlyProcessed[$_]).TotalSeconds -gt 60
                                    })
                                    foreach ($key in $stale) { $recentlyProcessed.Remove($key) }

                                    # Sanitize filename for CLI safety; keep path intact for Claude.
                                    $fileName     = Split-Path $filePath -Leaf
                                    $safeFileName = $fileName -replace '["$`]', '_'
                                    $pendingFiles.Add(@{ Path = $filePath; SafeName = $safeFileName })
                                    $lastEventTime = $now
                                    Write-WorkerLog "Queued: $filePath ($($pendingFiles.Count) pending)"
                                }
                            }
                        }

                        # Flush once the folder has been quiet for CoalesceWindow seconds.
                        # Note: WaitForChanged() returns one event per call, so a burst of N
                        # files arriving within the 2 s timeout takes N loop iterations to
                        # enqueue — the coalesce window starts from the *last* queued file.
                        if ($pendingFiles.Count -gt 0 -and
                            ($now - $lastEventTime).TotalSeconds -ge $CoalesceWindow) {
                            & $flushPending
                            $pendingFiles.Clear()
                        }
                    } catch {
                        Write-WorkerLog "ERROR in worker loop" -Exception $_
                    }
                }
            } finally {
                # Flush any events still pending on graceful stop.
                # Wrapped in its own try so a flush failure never skips Dispose().
                try {
                    if ($pendingFiles.Count -gt 0) {
                        Write-WorkerLog "Flushing $($pendingFiles.Count) pending file(s) on shutdown"
                        & $flushPending
                        $pendingFiles.Clear()
                    }
                } catch {
                    Write-WorkerLog "ERROR during shutdown flush" -Exception $_
                }
                $watcher.Dispose()
                Write-WorkerLog "Worker stopped, watcher disposed"
            }
        })
        $null = $ps.BeginInvoke()

        # Surface unhandled worker failures back to the server log.  Only 'Failed'
        # is logged — 'Completed' is the normal exit via StopFlag and 'Stopped' is
        # the forced exit from $ps.Stop() in Stop-InboxWatcher.
        $eventJob = Register-ObjectEvent -InputObject $ps -EventName 'InvocationStateChanged' `
            -MessageData @{ Path = $resolvedPath; LogPath = $logPath } -Action {
                if ($Event.SourceEventArgs.InvocationStateInfo.State -eq 'Failed') {
                    $err = $Event.SourceEventArgs.InvocationStateInfo.Reason?.Message ?? 'unknown error'
                    Add-Content -LiteralPath $Event.MessageData.LogPath `
                        -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [InboxWatcher] Worker FAILED for $($Event.MessageData.Path): $err" `
                        -ErrorAction SilentlyContinue
                }
            }

        $script:Workers.Add(@{ PS = $ps; StopFlag = $stopFlag; EventJob = $eventJob })
        Write-BotLog -Level Info -Message "[InboxWatcher] Worker started for: $resolvedPath (filter: $filter, events: $($events -join ', '))"
    }

    if ($script:Workers.Count -gt 0) {
        $script:Initialized = $true
        Write-BotLog -Level Info -Message "[InboxWatcher] Initialization complete. $($script:Workers.Count) watcher(s) active. Log: $logPath"
    }
}


function Stop-InboxWatcher {
    Write-BotLog -Level Debug -Message "[InboxWatcher] Stopping all inbox watchers"

    # Signal all workers to exit cooperatively. Each worker checks StopFlag[0]
    # after each WaitForChanged timeout (2 s), so 2.5 s gives one full cycle.
    foreach ($worker in $script:Workers) {
        $worker.StopFlag[0] = $true
    }
    Start-Sleep -Milliseconds 2500

    foreach ($worker in $script:Workers) {
        # Unregister the failure-notification event before stopping so it doesn't
        # fire for the intentional Stopped transition.
        if ($worker.EventJob) {
            Unregister-Event -SourceIdentifier $worker.EventJob.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $worker.EventJob -Force -ErrorAction SilentlyContinue
        }
        try {
            $worker.PS.Stop()
            $worker.PS.Runspace.Close()
            $worker.PS.Dispose()
        } catch {}
    }
    $script:Workers.Clear()
    $script:Initialized = $false

    Write-BotLog -Level Debug -Message "[InboxWatcher] All inbox watchers stopped"
}

Export-ModuleMember -Function @(
    'Initialize-InboxWatcher',
    'Stop-InboxWatcher'
)
