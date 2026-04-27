function Invoke-SessionUpdate {
    param(
        [hashtable]$Arguments
    )
    
    # Define paths
    $stateFile = Join-Path $global:DotbotProjectRoot ".bot\workspace\sessions\runs\session-state.json"
    
    # Check if state file exists
    if (-not (Test-Path $stateFile)) {
        return @{
            success = $false
            error = "No active session found. Initialize a session first."
        }
    }
    
    # Read current state
    try {
        $state = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    } catch {
        return @{
            success = $false
            error = "Failed to read session state: $_"
        }
    }
    
    # Update fields that were provided
    if ($Arguments.ContainsKey('current_task_id')) {
        $state.current_task_id = $Arguments.current_task_id
    }
    if ($Arguments.ContainsKey('status')) {
        $state.status = $Arguments.status
    }
    if ($Arguments.ContainsKey('auth_method')) {
        $state.auth_method = $Arguments.auth_method
    }
    if ($Arguments.ContainsKey('tasks_failed')) {
        $state.tasks_failed = $Arguments.tasks_failed
    }
    if ($Arguments.ContainsKey('tasks_skipped')) {
        $state.tasks_skipped = $Arguments.tasks_skipped
    }
    if ($Arguments.ContainsKey('consecutive_failures')) {
        $state.consecutive_failures = $Arguments.consecutive_failures
    }
    
    # Update last_update timestamp
    $state.last_update = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Write state atomically (write to temp file, then move)
    $tempFile = "$stateFile.tmp"
    try {
        $state | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Force
        Move-Item -Path $tempFile -Destination $stateFile -Force
        
        return @{
            success = $true
            state = $state
            message = "Session state updated"
        }
    } catch {
        # Clean up temp file if it exists
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
        return @{
            success = $false
            error = "Failed to update session state: $_"
        }
    }
}
