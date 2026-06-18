<#
.SYNOPSIS
MCP executor — invoke a named MCP tool with the declared arguments.

.DESCRIPTION
Entry point for workflows that chain tool calls without an AI. Loads the
PowerShell MCP tool surface and invokes the named tool function with the
declared arguments.
#>

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    $toolName = if ($Task.Contains('tool_name') -and $Task['tool_name']) {
        [string]$Task['tool_name']
    } elseif ($Task.Contains('mcp_tool') -and $Task['mcp_tool']) {
        [string]$Task['mcp_tool']
    } else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($toolName)) {
        return @{
            Success  = $false
            Message  = "mcp executor requires tool_name or mcp_tool."
            ExitCode = 2
        }
    }

    $toolArgs = if ($Task.Contains('tool_arguments') -and $Task['tool_arguments']) {
        $Task['tool_arguments']
    } elseif ($Task.Contains('mcp_args') -and $Task['mcp_args']) {
        $Task['mcp_args']
    } else {
        @{}
    }
    if ($toolArgs -is [PSCustomObject]) {
        $bag = @{}
        foreach ($p in $toolArgs.PSObject.Properties) { $bag[$p.Name] = $p.Value }
        $toolArgs = $bag
    }
    $argCount = if ($toolArgs -is [System.Collections.IDictionary]) { $toolArgs.Count } else { @($toolArgs).Count }
    $toolFunc = ConvertTo-ToolFunctionName -ToolName $toolName

    try {
        $result = Invoke-McpToolFromSurface -RunContext $RunContext -ToolFunction $toolFunc -ToolArguments $toolArgs
        return @{
            Success     = $true
            Message     = "MCP tool '$toolName' completed ($argCount argument(s))."
            ExitCode    = 0
            tool_name   = $toolName
            arg_count   = $argCount
            run_id      = $RunContext['run_id']
            mcp_result  = $result
        }
    } catch {
        return @{
            Success     = $false
            Message     = "MCP tool '$toolName' failed: $($_.Exception.Message)"
            ExitCode    = 1
            tool_name   = $toolName
            arg_count   = $argCount
            run_id      = $RunContext['run_id']
        }
    }
}

function ConvertTo-ToolFunctionName {
    param([Parameter(Mandatory)][string]$ToolName)
    $parts = $ToolName -split '[_-]' | Where-Object { $_ }
    $capitalParts = foreach ($p in $parts) {
        $p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1)
    }
    'Invoke-' + ($capitalParts -join '')
}

function Invoke-McpToolFromSurface {
    param(
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$ToolFunction,
        [Parameter(Mandatory)]$ToolArguments
    )

    if ($RunContext.Contains('bot_root') -and $RunContext['bot_root']) {
        $global:DotbotBotRoot = [string]$RunContext['bot_root']
    }
    if ($RunContext.Contains('project_root') -and $RunContext['project_root']) {
        $global:DotbotProjectRoot = [string]$RunContext['project_root']
    }

    if ($RunContext.Contains('runtime_root') -and $RunContext['runtime_root']) {
        $runtimeRoot = [string]$RunContext['runtime_root']
        Import-Module (Join-Path $runtimeRoot 'Modules' 'Dotbot.Runtime' 'Dotbot.Runtime.psd1') -Force -DisableNameChecking -Global
        $workflowModule = Join-Path $runtimeRoot 'Modules' 'Dotbot.Workflow' 'Dotbot.Workflow.psd1'
        if (Test-Path -LiteralPath $workflowModule -PathType Leaf) {
            Import-Module $workflowModule -Force -DisableNameChecking -Global
        }
    }

    $toolsDir = if ($RunContext.Contains('mcp_tools_dir') -and $RunContext['mcp_tools_dir']) {
        [string]$RunContext['mcp_tools_dir']
    } elseif ($RunContext.Contains('runtime_root') -and $RunContext['runtime_root']) {
        Join-Path ([string]$RunContext['runtime_root']) '..' 'mcp' 'tools'
    } else {
        $null
    }
    if (-not $toolsDir -or -not (Test-Path -LiteralPath $toolsDir -PathType Container)) {
        throw "MCP tools directory not found: $toolsDir"
    }

    Get-ChildItem -LiteralPath $toolsDir -Directory -ErrorAction Stop | ForEach-Object {
        $scriptPath = Join-Path $_.FullName 'script.ps1'
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) { . $scriptPath }
    }

    if (-not (Get-Command -Name $ToolFunction -ErrorAction SilentlyContinue)) {
        throw "MCP tool function '$ToolFunction' not found."
    }
    & $ToolFunction -Arguments $ToolArguments
}

Export-ModuleMember -Function Invoke-Executor
