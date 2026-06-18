<#
.SYNOPSIS
    Helper functions for MCP server
.DESCRIPTION
    Shared utility functions for JSON-RPC communication and date parsing
#>


function Write-JsonRpcResponse {
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )
    
    try {
        $json = $Response | ConvertTo-Json -Depth 100 -Compress
        # Ensure no embedded newlines in JSON (spec requirement)
        if ($json -match '[\r\n]') {
            throw "JSON contains embedded newlines, which violates MCP spec"
        }
        # MCP spec: Messages delimited by newlines (LF, not CRLF)
        [Console]::Out.Write($json)
        [Console]::Out.Write("`n")
        [Console]::Out.Flush()
    }
    catch {
        [Console]::Error.WriteLine("Failed to serialize response: $_")
        throw
    }
}

function Write-JsonRpcError {
    param(
        [Parameter(Mandatory)]
        [object]$Id,
        
        [Parameter(Mandatory)]
        [int]$Code,
        
        [Parameter(Mandatory)]
        [string]$Message,
        
        [object]$Data = $null
    )
    
    $error = @{
        jsonrpc = '2.0'
        id = $Id
        error = @{
            code = $Code
            message = $Message
        }
    }
    
    if ($null -ne $Data) {
        $error.error.data = $Data
    }
    
    Write-JsonRpcResponse -Response $error
}

function Get-DateFromString {
    param(
        [string]$DateString,
        [string]$Format = $null
    )
    
    if ([string]::IsNullOrWhiteSpace($DateString)) {
        return [DateTime]::Now
    }
    
    # Try parsing with format if provided
    if ($Format) {
        try {
            return [DateTime]::ParseExact($DateString, $Format, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            throw "Failed to parse date '$DateString' with format '$Format': $_"
        }
    }
    
    # Try standard parsing
    try {
        return [DateTime]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "Failed to parse date '$DateString': $_"
    }
}

