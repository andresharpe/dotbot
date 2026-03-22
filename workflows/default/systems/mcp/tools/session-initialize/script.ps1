function Invoke-SessionInitialize {
    param(
        [hashtable]$Arguments
    )
    
    $sessionType = $Arguments.session_type
    
    # Define paths
    $autonomousDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\sessions\runs"
    $stateFile = Join-Path $autonomousDir "session-state.json"
    $lockFile = Join-Path $autonomousDir "session.lock"
    
    # Ensure autonomous directory exists
    if (-not (Test-Path $autonomousDir)) {
        New-Item -ItemType Directory -Path $autonomousDir -Force | Out-Null
    }
    
    # Check for existing lock
    if (Test-Path $lockFile) {
        try {
            $lockContent = Get-Content -Path $lockFile -Raw | ConvertFrom-Json
            $lockTime = [DateTime]::Parse($lockContent.locked_at)
            $hoursSinceLock = ([DateTime]::UtcNow - $lockTime).TotalHours

            $isStale = $false

            # Check if owning process is dead (orphaned lock)
            if ($lockContent.process_id) {
                $lockProcess = Get-Process -Id $lockContent.process_id -ErrorAction SilentlyContinue
                if (-not $lockProcess) {
                    $isStale = $true
                }
            }

            # Check if lock is older than 1 hour
            if ($hoursSinceLock -ge 1) {
                $isStale = $true
            }

            if ($isStale) {
                # Remove stale/orphaned lock
                Remove-Item -Path $lockFile -Force
            } else {
                return @{
                    success = $false
                    error = "Session is already locked. Another session may be running."
                    locked_by = $lockContent.session_id
                    locked_at = $lockContent.locked_at
                }
            }
        } catch {
            # If we can't read the lock, remove it
            Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Create session ID from timestamp
    $sessionId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
    
    # Create initial state
    $state = @{
        session_id = $sessionId
        session_type = $sessionType
        start_time = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        current_task_id = $null
        tasks_completed = 0
        tasks_failed = 0
        tasks_skipped = 0
        consecutive_failures = 0
        auth_method = "claude_pro"
        status = "running"
        last_update = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    
    # Write state file
    try {
        $state | ConvertTo-Json -Depth 10 | Set-Content -Path $stateFile -Force
    } catch {
        return @{
            success = $false
            error = "Failed to create session state file: $_"
        }
    }
    
    # Create lock file
    $lock = @{
        session_id = $sessionId
        locked_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        process_id = $PID
    }
    
    try {
        $lock | ConvertTo-Json -Depth 10 | Set-Content -Path $lockFile -Force
    } catch {
        return @{
            success = $false
            error = "Failed to acquire session lock: $_"
        }
    }
    
    return @{
        success = $true
        session = $state
        message = "Session initialized: $sessionId"
    }
}
