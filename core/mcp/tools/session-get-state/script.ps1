function Invoke-SessionGetState {
    param(
        [hashtable]$Arguments
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = "Stop"
    
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
        
        return @{
            success = $true
            state = $state
        }
    } catch {
        return @{
            success = $false
            error = "Failed to read session state: $_"
        }
    }
}
