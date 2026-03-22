function Invoke-DevLogs {
    param(
        [hashtable]$Arguments
    )
    
    # Import helpers
    $coreHelpersPath = Join-Path $PSScriptRoot '..\..\core-helpers.psm1'
    Import-Module $coreHelpersPath -Force -DisableNameChecking -WarningAction SilentlyContinue
    
    $timer = Start-ToolTimer
    
    try {
        # Use project root detected by MCP server
        $solutionRoot = $global:DotbotProjectRoot
        if (-not $solutionRoot -or -not (Test-Path (Join-Path $solutionRoot '.bot'))) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_logs" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/View-Logs.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Check for View-Logs script
        $scriptPath = Join-Path $solutionRoot '.bot\hooks\dev\View-Logs.ps1'
        if (-not (Test-Path $scriptPath)) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_logs" `
                -Version "1.0.0" `
                -Summary "Failed: View-Logs.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "View-Logs script not found at: $scriptPath")) `
                -Source ".bot/hooks/dev/View-Logs.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Parse arguments with defaults
        $environment = if ($Arguments.environment) { $Arguments.environment } else { "dev" }
        $type = if ($Arguments.type) { $Arguments.type } else { "both" }
        $lines = if ($Arguments.lines) { [int]$Arguments.lines } else { 50 }
        $follow = if ($Arguments.follow) { $Arguments.follow } else { $false }
        $logLevel = if ($Arguments.logLevel) { $Arguments.logLevel } else { $null }
        
        # Build script arguments (use hashtable for splatting)
        $scriptArgs = @{
            Environment = $environment
            Type = $type
            Lines = $lines
        }
        
        if ($follow) {
            $scriptArgs.Follow = $true
        }
        
        if ($logLevel -and $logLevel.Count -gt 0) {
            $scriptArgs.LogLevel = $logLevel
        }
        
        # Change to project root so git commands work
        Push-Location $solutionRoot
        try {
            # Execute the View-Logs script
            $output = & $scriptPath @scriptArgs 2>&1 | Out-String
        }
        finally {
            Pop-Location
        }
        
        $duration = Get-ToolDuration -Stopwatch $timer
        
        # Build response data
        $data = @{
            solution_root = $solutionRoot
            script_executed = $scriptPath
            environment = $environment
            type = $type
            lines = $lines
            follow = $follow
            logLevel = $logLevel
        }
        
        if ($output) {
            $data.output = $output.Trim()
        }
        
        $summary = "Viewed $environment $type logs ($lines lines)"
        if ($follow) {
            $summary += " in follow mode"
        }
        
        return New-EnvelopeResponse `
            -Tool "dev_logs" `
            -Version "1.0.0" `
            -Summary $summary `
            -Data $data `
            -Source ".bot/hooks/dev/View-Logs.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_logs" `
            -Version "1.0.0" `
            -Summary "Failed to view logs: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source ".bot/hooks/dev/View-Logs.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
