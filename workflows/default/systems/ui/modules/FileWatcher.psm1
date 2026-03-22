<#
.SYNOPSIS
FileSystemWatcher-based change notification system

.DESCRIPTION
Provides event-driven file change notifications instead of polling.
Maintains in-memory state that is updated on file changes.
#>

# Script-scoped state
$script:WatcherState = @{
    Watchers = @{}
    LastChanges = @{}
    StateCache = $null
    StateCacheTime = [DateTime]::MinValue
    ActivityPosition = 0
    Initialized = $false
}

function Initialize-FileWatchers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BotRoot
    )

    if ($script:WatcherState.Initialized) {
        return
    }

    Write-Verbose "[FileWatcher] Initializing file watchers for: $BotRoot"

    # Watch tasks directories
    $tasksDirs = @(
        (Join-Path $BotRoot "workspace\tasks\todo"),
        (Join-Path $BotRoot "workspace\tasks\in-progress"),
        (Join-Path $BotRoot "workspace\tasks\done")
    )

    foreach ($dir in $tasksDirs) {
        if (-not (Test-Path $dir)) {
            Write-Verbose "[FileWatcher] Creating directory: $dir"
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }

        try {
            $watcher = New-Object System.IO.FileSystemWatcher
            $watcher.Path = $dir
            $watcher.Filter = "*.json"
            $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor
                                    [System.IO.NotifyFilters]::FileName -bor
                                    [System.IO.NotifyFilters]::CreationTime
            $watcher.InternalBufferSize = 65536  # 64KB for high-activity directories
            $watcher.EnableRaisingEvents = $true

            # Register event handlers
            Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
                $script:WatcherState.LastChanges['tasks'] = [DateTime]::UtcNow
                $script:WatcherState.StateCache = $null  # Invalidate cache
            } | Out-Null

            Register-ObjectEvent -InputObject $watcher -EventName Created -Action {
                $script:WatcherState.LastChanges['tasks'] = [DateTime]::UtcNow
                $script:WatcherState.StateCache = $null
            } | Out-Null

            Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action {
                $script:WatcherState.LastChanges['tasks'] = [DateTime]::UtcNow
                $script:WatcherState.StateCache = $null
            } | Out-Null

            $script:WatcherState.Watchers[$dir] = $watcher
            Write-Verbose "[FileWatcher] Watching tasks directory: $dir"
        } catch {
            Write-Warning "[FileWatcher] Failed to create watcher for $dir : $_"
        }
    }

    # Watch product docs directory
    $productDir = Join-Path $BotRoot "workspace\product"
    if (-not (Test-Path $productDir)) {
        New-Item -Path $productDir -ItemType Directory -Force | Out-Null
    }

    try {
        $productWatcher = New-Object System.IO.FileSystemWatcher
        $productWatcher.Path = $productDir
        $productWatcher.Filter = "*.md"
        $productWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor
                                       [System.IO.NotifyFilters]::FileName -bor
                                       [System.IO.NotifyFilters]::CreationTime
        $productWatcher.InternalBufferSize = 32768
        $productWatcher.EnableRaisingEvents = $true

        Register-ObjectEvent -InputObject $productWatcher -EventName Changed -Action {
            $script:WatcherState.LastChanges['product'] = [DateTime]::UtcNow
            $script:WatcherState.StateCache = $null
        } | Out-Null

        Register-ObjectEvent -InputObject $productWatcher -EventName Created -Action {
            $script:WatcherState.LastChanges['product'] = [DateTime]::UtcNow
            $script:WatcherState.StateCache = $null
        } | Out-Null

        Register-ObjectEvent -InputObject $productWatcher -EventName Deleted -Action {
            $script:WatcherState.LastChanges['product'] = [DateTime]::UtcNow
            $script:WatcherState.StateCache = $null
        } | Out-Null

        $script:WatcherState.Watchers[$productDir] = $productWatcher
        Write-Verbose "[FileWatcher] Watching product directory: $productDir"
    } catch {
        Write-Warning "[FileWatcher] Failed to create product watcher: $_"
    }

    # Watch session state file
    $sessionsDir = Join-Path $BotRoot "workspace\sessions\runs"
    if (-not (Test-Path $sessionsDir)) {
        New-Item -Path $sessionsDir -ItemType Directory -Force | Out-Null
    }

    try {
        $sessionWatcher = New-Object System.IO.FileSystemWatcher
        $sessionWatcher.Path = $sessionsDir
        $sessionWatcher.Filter = "session-state.json"
        $sessionWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
        $sessionWatcher.InternalBufferSize = 32768
        $sessionWatcher.EnableRaisingEvents = $true

        Register-ObjectEvent -InputObject $sessionWatcher -EventName Changed -Action {
            $script:WatcherState.LastChanges['session'] = [DateTime]::UtcNow
            $script:WatcherState.StateCache = $null
        } | Out-Null

        $script:WatcherState.Watchers[$sessionsDir] = $sessionWatcher
        Write-Verbose "[FileWatcher] Watching session directory: $sessionsDir"
    } catch {
        Write-Warning "[FileWatcher] Failed to create session watcher: $_"
    }

    # Watch control signals directory
    $controlDir = Join-Path $BotRoot ".control"
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    try {
        $controlWatcher = New-Object System.IO.FileSystemWatcher
        $controlWatcher.Path = $controlDir
        $controlWatcher.Filter = "*.signal"
        $controlWatcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
                                       [System.IO.NotifyFilters]::CreationTime
        $controlWatcher.InternalBufferSize = 32768
        $controlWatcher.EnableRaisingEvents = $true

        Register-ObjectEvent -InputObject $controlWatcher -EventName Created -Action {
            $script:WatcherState.LastChanges['control'] = [DateTime]::UtcNow
            $script:WatcherState.StateCache = $null
        } | Out-Null

        Register-ObjectEvent -InputObject $controlWatcher -EventName Deleted -Action {
            $script:WatcherState.LastChanges['control'] = [DateTime]::UtcNow
            $script:WatcherState.StateCache = $null
        } | Out-Null

        $script:WatcherState.Watchers["$controlDir-signals"] = $controlWatcher
        Write-Verbose "[FileWatcher] Watching control signals: $controlDir"
    } catch {
        Write-Warning "[FileWatcher] Failed to create control signal watcher: $_"
    }

    # Watch activity log for appends
    $activityLog = Join-Path $controlDir "activity.jsonl"
    try {
        $activityWatcher = New-Object System.IO.FileSystemWatcher
        $activityWatcher.Path = $controlDir
        $activityWatcher.Filter = "activity.jsonl"
        $activityWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor
                                        [System.IO.NotifyFilters]::Size
        $activityWatcher.InternalBufferSize = 32768
        $activityWatcher.EnableRaisingEvents = $true

        Register-ObjectEvent -InputObject $activityWatcher -EventName Changed -Action {
            $script:WatcherState.LastChanges['activity'] = [DateTime]::UtcNow
        } | Out-Null

        $script:WatcherState.Watchers["$controlDir-activity"] = $activityWatcher
        Write-Verbose "[FileWatcher] Watching activity log: $activityLog"
    } catch {
        Write-Warning "[FileWatcher] Failed to create activity watcher: $_"
    }

    # Initialize change timestamps
    $script:WatcherState.LastChanges['tasks'] = [DateTime]::UtcNow
    $script:WatcherState.LastChanges['session'] = [DateTime]::UtcNow
    $script:WatcherState.LastChanges['control'] = [DateTime]::UtcNow
    $script:WatcherState.LastChanges['activity'] = [DateTime]::UtcNow
    $script:WatcherState.LastChanges['product'] = [DateTime]::UtcNow

    $script:WatcherState.Initialized = $true
    Write-Verbose "[FileWatcher] Initialization complete"
}

function Get-LastChangeTime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category
    )

    if ($script:WatcherState.LastChanges.ContainsKey($Category)) {
        return $script:WatcherState.LastChanges[$Category]
    }
    return [DateTime]::MinValue
}

function Test-StateChanged {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$Since
    )

    foreach ($change in $script:WatcherState.LastChanges.Values) {
        if ($change -gt $Since) {
            return $true
        }
    }
    return $false
}

function Get-CachedState {
    return $script:WatcherState.StateCache
}

function Set-CachedState {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    $script:WatcherState.StateCache = $State
    $script:WatcherState.StateCacheTime = [DateTime]::UtcNow
}

function Get-StateCacheTime {
    return $script:WatcherState.StateCacheTime
}

function Clear-StateCache {
    $script:WatcherState.StateCache = $null
    $script:WatcherState.StateCacheTime = [DateTime]::MinValue
}

function Stop-FileWatchers {
    Write-Verbose "[FileWatcher] Stopping all file watchers"

    foreach ($watcher in $script:WatcherState.Watchers.Values) {
        try {
            $watcher.EnableRaisingEvents = $false
            $watcher.Dispose()
        } catch {
            Write-Warning "[FileWatcher] Error disposing watcher: $_"
        }
    }
    $script:WatcherState.Watchers.Clear()
    $script:WatcherState.Initialized = $false

    Write-Verbose "[FileWatcher] All watchers stopped"
}

Export-ModuleMember -Function @(
    'Initialize-FileWatchers',
    'Get-LastChangeTime',
    'Test-StateChanged',
    'Get-CachedState',
    'Set-CachedState',
    'Get-StateCacheTime',
    'Clear-StateCache',
    'Stop-FileWatchers'
)
