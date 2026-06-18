function Invoke-DevStop {
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
                -Tool "dev_stop" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/Stop-Dev.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Resolve Stop-Dev.ps1 through the layered hook chain so a project
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
            Where-Object Name -eq 'Stop-Dev.ps1' |
            Select-Object -First 1
        if (-not $devHook) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_stop" `
                -Version "1.0.0" `
                -Summary "Failed: Stop-Dev.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "Dev hook 'Stop-Dev.ps1' not found in project (.bot/hooks/dev/) or framework (<DOTBOT_HOME>/src/hooks/dev/).")) `
                -Source ".bot/hooks/dev/Stop-Dev.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        $scriptPath = $devHook.Path
        
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
