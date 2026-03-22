function Invoke-DevRelease {
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
                -Tool "dev_release" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/Release-DevToProd.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Check for release script
        $scriptPath = Join-Path $solutionRoot '.bot\hooks\dev\Release-DevToProd.ps1'
        if (-not (Test-Path $scriptPath)) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_release" `
                -Version "1.0.0" `
                -Summary "Failed: Release-DevToProd.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "Release script not found at: $scriptPath")) `
                -Source ".bot/hooks/dev/Release-DevToProd.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Change to project root
        Push-Location $solutionRoot
        try {
            # Execute the release script and capture return value
            $result = & $scriptPath 2>&1
            
            # Separate console output from return value
            $consoleOutput = @()
            $returnValue = $null
            foreach ($item in $result) {
                if ($item -is [hashtable]) {
                    $returnValue = $item
                } else {
                    $consoleOutput += $item
                }
            }
            $output = ($consoleOutput | Out-String).Trim()
        }
        finally {
            Pop-Location
        }
        
        $duration = Get-ToolDuration -Stopwatch $timer
        
        # Build response data
        $data = @{
            solution_root = $solutionRoot
            script_executed = $scriptPath
        }
        
        if ($returnValue) {
            $data.status = $returnValue.status
            $data.api_url = $returnValue.api_url
            $data.pid = $returnValue.pid
            $data.configuration = $returnValue.configuration
        }
        
        if ($output) {
            $data.output = $output
        }
        
        $summary = if ($returnValue.api_url) {
            "Development environment started in Release mode. API: $($returnValue.api_url)"
        } else {
            "Development environment started in Release mode."
        }
        
        return New-EnvelopeResponse `
            -Tool "dev_release" `
            -Version "1.0.0" `
            -Summary $summary `
            -Data $data `
            -Source ".bot/hooks/dev/Release-DevToProd.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_release" `
            -Version "1.0.0" `
            -Summary "Failed to start dev in release mode: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source ".bot/hooks/dev/Release-DevToProd.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
