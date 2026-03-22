function Invoke-DevDb {
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
                -Tool "dev_db" `
                -Version "1.0.0" `
                -Summary "Failed: not in a project directory." `
                -Data @{} `
                -Errors @((New-ErrorObject -Code "PROJECT_NOT_FOUND" -Message "Not in a project directory (no .bot folder found)")) `
                -Source ".bot/hooks/dev/Query-Db.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Check for Query-Db script
        $scriptPath = Join-Path $solutionRoot '.bot\hooks\dev\Query-Db.ps1'
        if (-not (Test-Path $scriptPath)) {
            $duration = Get-ToolDuration -Stopwatch $timer
            return New-EnvelopeResponse `
                -Tool "dev_db" `
                -Version "1.0.0" `
                -Summary "Failed: Query-Db.ps1 not found." `
                -Data @{ solution_root = $solutionRoot } `
                -Errors @((New-ErrorObject -Code "SCRIPT_NOT_FOUND" -Message "Query-Db script not found at: $scriptPath")) `
                -Source ".bot/hooks/dev/Query-Db.ps1" `
                -DurationMs $duration `
                -Host (Get-McpHost)
        }
        
        # Parse arguments with defaults
        $environment = if ($Arguments.environment) { $Arguments.environment } else { "dev" }
        $query = if ($Arguments.query) { $Arguments.query } else { $null }
        $table = if ($Arguments.table) { $Arguments.table } else { $null }
        $limit = if ($Arguments.limit) { [int]$Arguments.limit } else { 20 }
        
        # Build script arguments (use hashtable for splatting)
        $scriptArgs = @{
            Environment = $environment
            Limit = $limit
        }
        
        if ($query) {
            $scriptArgs.Query = $query
        }
        
        if ($table) {
            $scriptArgs.Table = $table
        }
        
        # Change to project root so git commands work
        Push-Location $solutionRoot
        try {
            # Execute the Query-Db script
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
            limit = $limit
        }
        
        if ($query) { $data.query = $query }
        if ($table) { $data.table = $table }
        
        if ($output) {
            $data.output = $output.Trim()
        }
        
        $queryDesc = if ($table) { "table $table" } elseif ($query) { "custom query" } else { "tables list" }
        $summary = "Queried $environment database ($queryDesc)"
        
        return New-EnvelopeResponse `
            -Tool "dev_db" `
            -Version "1.0.0" `
            -Summary $summary `
            -Data $data `
            -Source ".bot/hooks/dev/Query-Db.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    catch {
        $duration = Get-ToolDuration -Stopwatch $timer
        return New-EnvelopeResponse `
            -Tool "dev_db" `
            -Version "1.0.0" `
            -Summary "Failed to query database: $_" `
            -Data @{} `
            -Errors @((New-ErrorObject -Code "EXECUTION_FAILED" -Message "$_")) `
            -Source ".bot/hooks/dev/Query-Db.ps1" `
            -DurationMs $duration `
            -Host (Get-McpHost)
    }
    finally {
        Remove-Module core-helpers -ErrorAction SilentlyContinue
    }
}
