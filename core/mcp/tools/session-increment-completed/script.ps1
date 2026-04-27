function Invoke-SessionIncrementCompleted {
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
    
    # Increment tasks_completed
    $state.tasks_completed++
    
    # Reset consecutive_failures to 0
    $state.consecutive_failures = 0
    
    # Update last_update timestamp
    $state.last_update = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Write state atomically
    $tempFile = "$stateFile.tmp"
    try {
        $state | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Force
        Move-Item -Path $tempFile -Destination $stateFile -Force
        
        return @{
            success = $true
            tasks_completed = $state.tasks_completed
            consecutive_failures = $state.consecutive_failures
            message = "Task completion incremented to $($state.tasks_completed)"
        }
    } catch {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
        return @{
            success = $false
            error = "Failed to update session state: $_"
        }
    }
}
