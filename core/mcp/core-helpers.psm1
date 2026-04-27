# Core Helper Functions
# Essential utilities for all MCP tools

#region Solution Discovery

function Find-SolutionRoot {
    <#
    .SYNOPSIS
    Walks up directory tree to find .bot directory
    #>
    param(
        [string]$StartPath = $PWD.Path
    )
    
    $current = Get-Item -Path $StartPath -ErrorAction SilentlyContinue
    
    while ($current) {
        $botPath = Join-Path $current.FullName '.bot'
        if (Test-Path $botPath -PathType Container) {
            return $current.FullName
        }
        $current = $current.Parent
    }
    
    return $null
}

#endregion

#region Error Codes

# Core error codes (used across all tools)
$script:CoreErrorCodes = @{
    DOTBOT_NOT_FOUND = "DOTBOT_NOT_FOUND"
    INVALID_PARAMETER = "INVALID_PARAMETER"
    INVALID_ARGUMENTS = "INVALID_ARGUMENTS"
    IO_ERROR = "IO_ERROR"
}

#endregion

#region Envelope Response

function New-ErrorObject {
    <#
    .SYNOPSIS
    Creates a structured error object
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Code,
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Path = $null,
        [hashtable]$Details = $null
    )
    
    $error = @{
        code = $Code
        message = $Message
    }
    if ($Path) { $error.path = $Path }
    if ($Details) { $error.details = $Details }
    return $error
}

function Start-ToolTimer {
    <#
    .SYNOPSIS
    Starts a stopwatch for timing tool execution
    #>
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function Get-ToolDuration {
    <#
    .SYNOPSIS
    Gets elapsed milliseconds from stopwatch
    #>
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Stopwatch]$Stopwatch
    )
    return [int]$Stopwatch.ElapsedMilliseconds
}

function Get-McpHost {
    <#
    .SYNOPSIS
    Detects the MCP host environment
    #>
    # Detect MCP host from environment
    if ($env:WARP_SESSION) { return "warp" }
    if ($env:CLAUDE_DESKTOP) { return "claude-desktop" }
    if ($env:CI) { return "ci" }
    return $null
}

function New-EnvelopeResponse {
    <#
    .SYNOPSIS
    Creates a standardized envelope response for MCP tools
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Tool,
        [Parameter(Mandatory)]
        [string]$Version,
        [Parameter(Mandatory)]
        [string]$Summary,
        [Parameter(Mandatory)]
        [hashtable]$Data,
        [array]$Warnings = @(),
        [array]$Errors = @(),
        [hashtable]$Intent = $null,
        [array]$Actions = $null,
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [int]$DurationMs,
        [string]$Host = $null,
        [string]$CorrelationId = $null,
        [string]$WriteTo = $null
    )
    
    # Auto-compute status based on errors and warnings
    $status = if ($Errors.Count -gt 0) { "error" } 
              elseif ($Warnings.Count -gt 0) { "warning" } 
              else { "ok" }
    
    $response = @{
        schema_id = "dotbot-mcp-response@1"
        tool = $Tool
        version = $Version
        status = $status
        summary = $Summary
        data = $Data
        warnings = $Warnings
        errors = $Errors
        audit = @{
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            duration_ms = $DurationMs
            source = $Source
        }
    }
    
    if ($Host) { $response.audit.host = $Host }
    if ($CorrelationId) { $response.audit.correlation_id = $CorrelationId }
    if ($WriteTo) { $response.audit.write_to = $WriteTo }
    if ($Intent) { $response.intent = $Intent }
    if ($Actions) { $response.actions = $Actions }
    
    return $response
}

function Assert-EnvelopeSchema {
    <#
    .SYNOPSIS
    Validates envelope response structure
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Response
    )
    
    # Basic validation
    $required = @('schema_id', 'tool', 'version', 'status', 'summary', 'data', 'warnings', 'errors', 'audit')
    foreach ($field in $required) {
        if (-not $Response.ContainsKey($field)) {
            throw "Missing required field: $field"
        }
    }
    
    if ($Response.status -notin @('ok', 'warning', 'error')) {
        throw "Invalid status: $($Response.status)"
    }
    
    # Validate audit required fields
    $auditRequired = @('timestamp', 'duration_ms', 'source')
    foreach ($field in $auditRequired) {
        if (-not $Response.audit.ContainsKey($field)) {
            throw "Missing required audit field: $field"
        }
    }
    
    return $true
}

#endregion

# Export all functions
Export-ModuleMember -Function @(
    'Find-SolutionRoot',
    'New-ErrorObject',
    'Start-ToolTimer',
    'Get-ToolDuration',
    'Get-McpHost',
    'New-EnvelopeResponse',
    'Assert-EnvelopeSchema'
)

# Export error codes
Export-ModuleMember -Variable @('CoreErrorCodes')
