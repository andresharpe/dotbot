function Invoke-DevStart {
    param(
        [hashtable]$Arguments
    )
    
    # Import helpers
    $coreHelpersPath = Join-Path $PSScriptRoot '..' '..' 'core-helpers.psm1'
    Import-Module $coreHelpersPath -Force -DisableNameChecking -WarningAction SilentlyContinue
    
    $timer = Start-ToolTimer
    
    try {
        # Use project root detected by MCP server
        $solutionRoot = $global:DotbotProjectRoot
        if (-not $solutionRoot -or -not (Test-Path (Join-Path $solutionRoot '.bot'))) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_start" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/Start-Dev.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Resolve Start-Dev.ps1 through the layered hook chain so a project
        # override at .bot/hooks/dev/ wins over the framework default at
        # <DOTBOT_HOME>/src/hooks/dev/.
        $botRoot = Join-Path $solutionRoot '.bot'
        if (-not (Get-Command Get-DotbotHookChain -ErrorAction SilentlyContinue)) {
            $contentResolverModule = Join-Path $botRoot 'src' 'runtime' 'Modules' 'Dotbot.Content' 'Dotbot.Content.psm1'
            if (-not (Test-Path $contentResolverModule)) {
                $dotbotHome = if ($env:DOTBOT_HOME) { $env:DOTBOT_HOME } else { Join-Path $HOME 'dotbot' }
                $contentResolverModule = Join-Path $dotbotHome 'src' 'runtime' 'Modules' 'Dotbot.Content' 'Dotbot.Content.psm1'
            }
            Import-Module $contentResolverModule -DisableNameChecking -Global
        }
        $devHook = Get-DotbotHookChain -BotRoot $botRoot -Phase dev |
            Where-Object Name -eq 'Start-Dev.ps1' |
            Select-Object -First 1
        if (-not $devHook) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_start" `
                -Version "1.0.0" `
                -Summary "Failed: Start-Dev.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "Dev hook 'Start-Dev.ps1' not found in project (.bot/hooks/dev/) or framework (<DOTBOT_HOME>/src/hooks/dev/).")) `
                -Source ".bot/hooks/dev/Start-Dev.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        $scriptPath = $devHook.Path
        
        # Build arguments
        $scriptArgs = @{}
        if ($Arguments.noLayout -eq $true) {
            $scriptArgs.NoLayout = $true
        }
        
        # Change to project root so git commands work
        Push-Location $solutionRoot
        try {
            # Execute the start script and capture return value
            $result = & $scriptPath @scriptArgs 2>&1
            
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
        
        # Include dashboard URL if returned
        if ($returnValue -and $returnValue.dashboard_url) {
            $data.dashboard_url = $returnValue.dashboard_url
            $data.status = $returnValue.status
        }
        
        if ($output) {
            $data.output = $output
        }
        
        $summary = if ($data.dashboard_url) {
            "Development environment started. Dashboard: $($data.dashboard_url)"
        } else {
            "Development environment started."
        }
        
        return New-EnvelopeResponse `
            -Tool "dev_start" `
            -Version "1.0.0" `
            -Summary $summary `
            -Data $data `
            -Source ".bot/hooks/dev/Start-Dev.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_start" `
            -Version "1.0.0" `
            -Summary "Failed to start dev environment: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source ".bot/hooks/dev/Start-Dev.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
