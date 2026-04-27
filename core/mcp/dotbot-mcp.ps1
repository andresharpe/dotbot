#!/usr/bin/env pwsh
# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
<#
.SYNOPSIS
    MCP Server in PowerShell with accurate date/time tools
.DESCRIPTION
    A pure PowerShell implementation of an MCP server that exposes
    deterministic date and time manipulation tools via stdio transport.
    Tools are dynamically loaded from the tools/ directory.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# Disable ANSI colors in error output
$PSStyle.OutputRendering = 'PlainText'

# Auto-detect project root by walking up from script location to find .git folder
$script:ProjectRoot = $null
$currentPath = $PSScriptRoot
while ($currentPath) {
    if (Test-Path (Join-Path $currentPath ".git")) {
        $script:ProjectRoot = $currentPath
        break
    }
    $parent = Split-Path $currentPath -Parent
    if ($parent -eq $currentPath) { break }  # Reached filesystem root
    $currentPath = $parent
}

if (-not $script:ProjectRoot) {
    [Console]::Error.WriteLine("FATAL: Could not auto-detect project root. No .git folder found in parent directories of $PSScriptRoot")
    exit 1
}

# Also export to global scope so dot-sourced tools can access it
$global:DotbotProjectRoot = $script:ProjectRoot

# Initialize structured logging (console disabled — stdout is MCP protocol)
$mcpControlDir = Join-Path $script:ProjectRoot ".bot\.control"
$mcpLogsDir = Join-Path $mcpControlDir "logs"
if (-not (Test-Path $mcpLogsDir)) { New-Item -Path $mcpLogsDir -ItemType Directory -Force | Out-Null }
$dotBotLogPath = Join-Path $PSScriptRoot "..\runtime\modules\DotBotLog.psm1"
if (Test-Path $dotBotLogPath) {
    Import-Module $dotBotLogPath -Force -DisableNameChecking
    Initialize-DotBotLog -LogDir $mcpLogsDir -ControlDir $mcpControlDir -ProjectRoot $script:ProjectRoot -ConsoleEnabled $false
}

# Diagnostic logging (stderr, separate from MCP protocol on stdout)
[Console]::Error.WriteLine("Project root: $($script:ProjectRoot)")
$tasksCheck = Join-Path $script:ProjectRoot ".bot\workspace\tasks"
if (Test-Path $tasksCheck) {
    [Console]::Error.WriteLine("Tasks directory: OK ($tasksCheck)")
} else {
    [Console]::Error.WriteLine("Tasks directory: MISSING ($tasksCheck)")
}

# Load helpers
. "$PSScriptRoot\dotbot-mcp-helpers.ps1"

# Import PowerShell YAML module for proper YAML parsing
try {
    Import-Module powershell-yaml -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("ERROR: powershell-yaml module not found. Install with: Install-Module -Name powershell-yaml")
    exit 1
}

# Load server metadata
$metadataPath = Join-Path $PSScriptRoot "metadata.yaml"
$script:serverMetadata = Get-Content $metadataPath -Raw | ConvertFrom-Yaml

# Discover and load tools
$toolsPath = Join-Path $PSScriptRoot "tools"
$tools = @{}

$toolDirs = Get-ChildItem -Path $toolsPath -Directory
foreach ($toolDirItem in $toolDirs) {
    $toolDir = $toolDirItem.FullName
    $scriptPath = Join-Path $toolDir "script.ps1"
    $metadataPath = Join-Path $toolDir "metadata.yaml"
    
    if ((Test-Path $scriptPath) -and (Test-Path $metadataPath)) {
        try {
            # Load tool script
            . $scriptPath
            
            # Load tool metadata
            $toolMetadata = Get-Content $metadataPath -Raw | ConvertFrom-Yaml
            
            # Store tool info
            $tools[$toolMetadata.name] = @{
                metadata = $toolMetadata
                scriptPath = $scriptPath
            }
        } catch {
            [Console]::Error.WriteLine("ERROR: Failed to load tool from $($toolDirItem.Name): $($_.Exception.Message)")
        }
    }
}

# Discover workflow tools: .bot/workflows/*/tools/
$workflowsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "..\workflows"
if (Test-Path $workflowsDir) {
    Get-ChildItem -Path $workflowsDir -Directory | ForEach-Object {
        $wfName = $_.Name
        $wfToolsDir = Join-Path $_.FullName "tools"
        if (Test-Path $wfToolsDir) {
            Get-ChildItem -Path $wfToolsDir -Directory | ForEach-Object {
                $toolDir = $_.FullName
                $scriptPath = Join-Path $toolDir "script.ps1"
                $metadataPath = Join-Path $toolDir "metadata.yaml"
                if ((Test-Path $scriptPath) -and (Test-Path $metadataPath)) {
                    try {
                        . $scriptPath
                        $toolMetadata = Get-Content $metadataPath -Raw | ConvertFrom-Yaml
                        # Register tool using its metadata name as-is (no automatic workflow prefixing)
                        # Note: name collisions across workflows are possible if tool names are not unique
                        $registeredName = $toolMetadata.name
                        $tools[$registeredName] = @{
                            metadata = $toolMetadata
                            scriptPath = $scriptPath
                            workflow = $wfName
                        }
                        [Console]::Error.WriteLine("Loaded workflow tool: $registeredName (from $wfName)")
                    } catch {
                        [Console]::Error.WriteLine("ERROR: Failed to load workflow tool $($_.Name) from $wfName`: $($_.Exception.Message)")
                    }
                }
            }
        }
    }
}

#region MCP Handlers

function Invoke-Initialize {
    param([hashtable]$Params)
    
    # Add project root to server info
    $serverInfo = @{}
    foreach ($key in $script:serverMetadata.serverInfo.Keys) {
        $serverInfo[$key] = $script:serverMetadata.serverInfo[$key]
    }
    $serverInfo.projectRoot = $script:ProjectRoot
    
    return @{
        protocolVersion = $script:serverMetadata.protocolVersion
        capabilities = $script:serverMetadata.capabilities
        serverInfo = $serverInfo
    }
}

function Invoke-ListTools {
    $toolList = @()
    
    foreach ($toolName in $tools.Keys) {
        $tool = $tools[$toolName]
        # Accept both camelCase (inputSchema) and snake_case (input_schema) keys
        $inputSchema = if ($tool.metadata.inputSchema) { $tool.metadata.inputSchema }
                       elseif ($tool.metadata.input_schema) { $tool.metadata.input_schema }
                       else { @{ type = 'object'; properties = @{}; required = @() } }

        # Ensure 'required' is always an array (MCP protocol requirement)
        if ($inputSchema.ContainsKey('required')) {
            if ($inputSchema.required -isnot [array]) {
                # Convert non-array to array
                if ($null -eq $inputSchema.required) {
                    $inputSchema.required = @()
                } else {
                    $inputSchema.required = @($inputSchema.required)
                }
            }
        } else {
            # Add empty required array if missing
            $inputSchema.required = @()
        }
        
        # Add additionalProperties: false for JSON Schema 2020-12 compliance
        if (-not $inputSchema.ContainsKey('additionalProperties')) {
            $inputSchema.additionalProperties = $false
        }
        
        $toolList += @{
            name = $tool.metadata.name
            description = $tool.metadata.description
            inputSchema = $inputSchema
        }
    }
    
    return @{
        tools = $toolList
    }
}

function Invoke-CallTool {
    param(
        [string]$Name,
        [hashtable]$Arguments
    )
    
    if (-not $tools.ContainsKey($Name)) {
        throw "Unknown tool: $Name"
    }
    
    try {
        # Convert tool name to function name: get_current_datetime -> Invoke-GetCurrentDateTime
        # ToUpperInvariant ensures Turkish/Azerbaijani locales don't fold "i" -> "İ".
        $parts = $Name -split '_'
        $capitalizedParts = foreach ($part in $parts) {
            $part.Substring(0,1).ToUpperInvariant() + $part.Substring(1)
        }
        $functionName = 'Invoke-' + ($capitalizedParts -join '')
        
        # Call the tool function (tools can access $script:ProjectRoot directly)
        $result = & $functionName -Arguments $Arguments
        
        $jsonText = $result | ConvertTo-Json -Depth 100 -Compress
        
        return @{
            content = @(
                @{
                    type = 'text'
                    text = $jsonText
                }
            )
        }
    }
    catch {
        throw "Tool execution failed: $_"
    }
}

#endregion

#region Main Loop

function Start-McpServerLoop {
    [Console]::Error.WriteLine("PowerShell MCP Date Server starting...")
    [Console]::Error.WriteLine("Loaded $($tools.Count) tools")
    
    while ($true) {
        try {
            $line = [Console]::ReadLine()
            
            if ([string]::IsNullOrEmpty($line)) {
                continue
            }
            
            $request = $line | ConvertFrom-Json -AsHashtable
            
            $method = $request.method
            $id = $request.id
            $params = if ($request.params) { $request.params } else { @{} }
            
            # Handle notifications (no id) separately
            if ($null -eq $id -and $method -like 'notifications/*') {
                # Notifications don't require a response
                continue
            }
            
            $result = switch ($method) {
                'initialize' { Invoke-Initialize -Params $params }
                'tools/list' { Invoke-ListTools }
                'tools/call' { 
                    Invoke-CallTool -Name $params.name -Arguments $(if ($params.arguments) { $params.arguments } else { @{} })
                }
                default {
                    if ($null -ne $id) {
                        Write-JsonRpcError -Id $id -Code -32601 -Message "Method not found: $method"
                    }
                    continue
                }
            }
            
            # Only send response for requests with an id
            if ($null -ne $id) {
                $response = @{
                    jsonrpc = '2.0'
                    id = $id
                    result = $result
                }
                
                Write-JsonRpcResponse -Response $response
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            [Console]::Error.WriteLine("Error: $errorMessage")
            
            if ($null -ne $id) {
                Write-JsonRpcError -Id $id -Code -32603 -Message $errorMessage
            }
        }
    }
}

#endregion

# Start the server
Start-McpServerLoop

