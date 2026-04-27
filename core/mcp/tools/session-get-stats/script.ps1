function Invoke-SessionGetStats {
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
    
    # Read state file
    try {
        $state = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
    } catch {
        return @{
            success = $false
            error = "Failed to read session state: $_"
        }
    }
    
    # Calculate runtime
    $startTime = [DateTime]::ParseExact($state.start_time, "MM/dd/yyyy HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $currentTime = [DateTime]::UtcNow
    $runtimeMinutes = ($currentTime - $startTime).TotalMinutes
    $runtimeHours = [Math]::Round($runtimeMinutes / 60, 2)
    
    # Calculate total tasks processed
    $totalProcessed = $state.tasks_completed + $state.tasks_failed + $state.tasks_skipped
    
    # Calculate rates
    $completionRate = if ($totalProcessed -gt 0) {
        [Math]::Round(($state.tasks_completed / $totalProcessed) * 100, 1)
    } else {
        0
    }
    
    $failureRate = if ($totalProcessed -gt 0) {
        [Math]::Round(($state.tasks_failed / $totalProcessed) * 100, 1)
    } else {
        0
    }
    
    $skipRate = if ($totalProcessed -gt 0) {
        [Math]::Round(($state.tasks_skipped / $totalProcessed) * 100, 1)
    } else {
        0
    }
    
    # Calculate average time per task
    $avgMinutesPerTask = if ($totalProcessed -gt 0) {
        [Math]::Round($runtimeMinutes / $totalProcessed, 1)
    } else {
        0
    }
    
    # Build summary message
    $summary = "Session $($state.session_id): $($state.tasks_completed) completed"
    if ($totalProcessed -gt 0) {
        $summary += " ($completionRate% success rate)"
    }
    $summary += " in $([Math]::Round($runtimeHours, 1))h"
    
    return @{
        success = $true
        session_id = $state.session_id
        session_type = $state.session_type
        status = $state.status
        runtime_minutes = [Math]::Round($runtimeMinutes, 1)
        runtime_hours = $runtimeHours
        tasks_completed = $state.tasks_completed
        tasks_failed = $state.tasks_failed
        tasks_skipped = $state.tasks_skipped
        total_processed = $totalProcessed
        consecutive_failures = $state.consecutive_failures
        completion_rate = $completionRate
        failure_rate = $failureRate
        skip_rate = $skipRate
        avg_minutes_per_task = $avgMinutesPerTask
        auth_method = $state.auth_method
        current_task_id = $state.current_task_id
        summary = $summary
    }
}
