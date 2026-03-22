function Invoke-DevDeploy {
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
                -Tool "dev_deploy" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/Start-Deploy.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Check for deploy script
        $scriptPath = Join-Path $solutionRoot '.bot\hooks\dev\Start-Deploy.ps1'
        if (-not (Test-Path $scriptPath)) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_deploy" `
                -Version "1.0.0" `
                -Summary "Failed: Start-Deploy.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "Deploy script not found at: $scriptPath")) `
                -Source ".bot/hooks/dev/Start-Deploy.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Extract bump parameter (default to 'patch')
        $bump = if ($Arguments.bump) { $Arguments.bump } else { 'patch' }
        
        # Change to project root so git commands work
        Push-Location $solutionRoot
        try {
            # Execute the deploy script and capture return value
            $result = & $scriptPath -Bump $bump 2>&1
            
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
        
        # Include run info if returned
        if ($returnValue -and $returnValue.status) {
            $data.status = $returnValue.status
            if ($returnValue.run_id) {
                $data.run_id = $returnValue.run_id
            }
            if ($returnValue.version) {
                $data.version = $returnValue.version
            }
        }
        
        if ($output) {
            $data.output = $output
        }
        
        $summary = if ($data.status -eq "triggered") {
            $versionInfo = if ($data.version) { " (v$($data.version))" } else { "" }
            "Deployment workflow triggered successfully$versionInfo."
        } else {
            "Deploy script completed."
        }
        
        return New-EnvelopeResponse `
            -Tool "dev_deploy" `
            -Version "1.0.0" `
            -Summary $summary `
            -Data $data `
            -Source ".bot/hooks/dev/Start-Deploy.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_deploy" `
            -Version "1.0.0" `
            -Summary "Failed to deploy: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source ".bot/hooks/dev/Start-Deploy.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
