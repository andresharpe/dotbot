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

# Auto-detect project root. In a linked git worktree, walking up looking for
# `.git` would stop at the worktree's gitfile rather than the main repo, so
# Resolve-DotbotProjectRoot prefers `git rev-parse --git-common-dir`.
. (Join-Path $PSScriptRoot 'Resolve-ProjectRoot.ps1')
$script:ProjectRoot = Resolve-DotbotProjectRoot -StartPath $PSScriptRoot

if (-not $script:ProjectRoot) {
    [Console]::Error.WriteLine("FATAL: Could not auto-detect project root. No .git folder found in parent directories of $PSScriptRoot")
    exit 1
}

# Also export to global scope so dot-sourced tools can access it
$global:DotbotProjectRoot = $script:ProjectRoot
Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -DisableNameChecking
$script:BotRoot = Join-Path $script:ProjectRoot ".bot"
# Tools call Invoke-RuntimeRequest without a -BotRoot argument; the helper
# pulls it from $global:DotbotBotRoot. Setting this once here keeps every
# tool script trivially short (§"each tool's script.ps1 should be
# under fifteen lines").
$global:DotbotBotRoot = $script:BotRoot

# Initialize structured logging (console disabled — stdout is MCP protocol)
$mcpControlDir = Join-Path $script:BotRoot ".control"
$mcpLogsDir = Join-Path $mcpControlDir "logs"
if (-not (Test-Path $mcpLogsDir)) { New-Item -Path $mcpLogsDir -ItemType Directory -Force | Out-Null }
$dotBotLogPath = Join-Path $PSScriptRoot "..\runtime\Modules\Dotbot.Logging\Dotbot.Logging.psd1"
if (Test-Path $dotBotLogPath) {
    Import-Module $dotBotLogPath -Force -DisableNameChecking
    Initialize-DotbotLog -LogDir $mcpLogsDir -ControlDir $mcpControlDir -ProjectRoot $script:ProjectRoot -ConsoleEnabled $false
}

# Diagnostic logging (stderr, separate from MCP protocol on stdout)
[Console]::Error.WriteLine("Project root: $($script:ProjectRoot)")
$tasksCheck = Join-Path $script:BotRoot "workspace" "tasks"
if (Test-Path $tasksCheck) {
    [Console]::Error.WriteLine("Tasks directory: OK ($tasksCheck)")
} else {
    [Console]::Error.WriteLine("Tasks directory: MISSING ($tasksCheck)")
}

# Load helpers
. "$PSScriptRoot\dotbot-mcp-helpers.ps1"
Import-Module "$PSScriptRoot\..\runtime\Modules\Dotbot.Workflow\Dotbot.Workflow.psd1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\..\runtime\Modules\ContentResolver\ContentResolver.psm1" -Force -DisableNameChecking

# discover the per-project runtime endpoint at startup. MCP tools are
# thin HTTP wrappers over the runtime; if the runtime isn't running we exit
# cleanly so Claude Code surfaces the diagnostic instead of every individual
# tool call failing with an opaque error.
Import-Module "$PSScriptRoot\..\runtime\Modules\Dotbot.Runtime\Dotbot.Runtime.psd1" -Force -DisableNameChecking -Global
try {
    $script:RuntimeEndpoint = Resolve-RuntimeEndpoint -BotRoot $script:BotRoot
    [Console]::Error.WriteLine("Runtime endpoint: $($script:RuntimeEndpoint.url) (source: $($script:RuntimeEndpoint.source))")
} catch {
    [Console]::Error.WriteLine("FATAL: $($_.Exception.Message)")
    [Console]::Error.WriteLine("HINT: Start the runtime with 'dotbot runtime-start'.")
    exit 1
}

# user story 8: every mutation is attributed to "mcp:<session>". The
# session ID is generated once per MCP server process and surfaced to tools
# via Get-McpActor (reads $env:DOTBOT_MCP_SESSION). We use a short random
# suffix so audit logs are easy to scan; uniqueness across simultaneous
# sessions matters more than cryptographic identity.
$script:McpSessionId = "{0:yyyyMMddHHmmss}-{1}" -f (Get-Date).ToUniversalTime(), ([System.Guid]::NewGuid().ToString('N').Substring(0,8))
$env:DOTBOT_MCP_SESSION = $script:McpSessionId
[Console]::Error.WriteLine("MCP session: $script:McpSessionId")

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

# discover workflow tools across both tiers (project + framework).
# Discover-Workflows resolves duplicates so a project override's tools win.
# Workflows declare tools under either `tools/` (new layout) or
# `systems/mcp/tools/` (legacy layout the pre-Phase-4 init normalised).
foreach ($wf in (Discover-Workflows -BotRoot $script:BotRoot)) {
        $wfName = $wf.name
        $wfToolsDirs = @(
            (Join-Path $wf.path "tools"),
            (Join-Path $wf.path "systems/mcp/tools")
        ) | Where-Object { Test-Path $_ }
        foreach ($wfToolsDir in $wfToolsDirs) {
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

# Selected stacks extend the tool catalog without copying framework content
# into the project. Parent stacks are returned before child stacks, so a
# child tool with the same metadata name takes precedence.
foreach ($stack in (Get-DotbotActiveStackChain -BotRoot $script:BotRoot)) {
    $stackToolsDirs = @(
        (Join-Path $stack.Path "tools"),
        (Join-Path $stack.Path "systems/mcp/tools")
    ) | Where-Object { Test-Path $_ }
    foreach ($stackToolsDir in $stackToolsDirs) {
        Get-ChildItem -Path $stackToolsDir -Directory | ForEach-Object {
            $scriptPath = Join-Path $_.FullName "script.ps1"
            $metadataPath = Join-Path $_.FullName "metadata.yaml"
            if ((Test-Path $scriptPath) -and (Test-Path $metadataPath)) {
                try {
                    . $scriptPath
                    $toolMetadata = Get-Content $metadataPath -Raw | ConvertFrom-Yaml
                    $tools[$toolMetadata.name] = @{
                        metadata = $toolMetadata
                        scriptPath = $scriptPath
                        stack = $stack.Name
                    }
                    [Console]::Error.WriteLine("Loaded stack tool: $($toolMetadata.name) (from $($stack.Name))")
                } catch {
                    [Console]::Error.WriteLine("ERROR: Failed to load stack tool from $($stack.Name): $($_.Exception.Message)")
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
    # The dotbot MCP server returns the full set of tool schemas eagerly,
    # with no deferral hints. Whether the calling harness chooses to defer
    # any of them is a harness-side decision (#366); dotbot's contract is
    # to make every schema available on the first tools/list call.
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
