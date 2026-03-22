function Invoke-DevStop {
    param(
        [hashtable]$Arguments
    )
    
    # Import helpers
    $coreHelpersPath = Join-Path $global:DotbotProjectRoot '.bot\systems\mcp\core-helpers.psm1'
    Import-Module $coreHelpersPath -Force -DisableNameChecking -WarningAction SilentlyContinue
    
    $timer = Start-ToolTimer
    
    try {
        # Use project root detected by MCP server
        $solutionRoot = $global:DotbotProjectRoot
        if (-not $solutionRoot -or -not (Test-Path (Join-Path $solutionRoot '.bot'))) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_stop" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/Stop-Dev.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Check for dev script
        $scriptPath = Join-Path $solutionRoot '.bot\hooks\dev\Stop-Dev.ps1'
        if (-not (Test-Path $scriptPath)) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_stop" `
                -Version "1.0.0" `
                -Summary "Failed: Stop-Dev.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "Dev script not found at: $scriptPath")) `
                -Source ".bot/hooks/dev/Stop-Dev.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Change to project root so git commands work
        Push-Location $solutionRoot
        try {
            # Execute the stop script
            $output = & $scriptPath 2>&1 | Out-String
        }
        finally {
            Pop-Location
        }
        
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_stop" `
            -Version "1.0.0" `
            -Summary "Development environment stopped." `
            -Data @{
                solution_root = $solutionRoot
                script_executed = $scriptPath
                output = $output.Trim()
            } `
            -Source ".bot/hooks/dev/Stop-Dev.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_stop" `
            -Version "1.0.0" `
            -Summary "Failed to stop dev environment: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source ".bot/hooks/dev/Stop-Dev.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
