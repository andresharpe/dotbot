<#
.SYNOPSIS
MCP executor — call an MCP tool with declared arguments via the runtime's
tool dispatch.

PRD-05 names this executor as the entry point for workflows that chain
tool calls without an AI. The actual MCP-tool dispatch surface arrives in
PRD-07; this file establishes the contract surface so the dispatcher (and
tests) have a real target. The follow-up patch will route through
$RunContext.RuntimeClient.

For now, the executor records the intent of calling the named tool and
returns success.
#>

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    $toolName = [string]$Task['tool_name']
    $toolArgs = if ($Task.Contains('tool_arguments') -and $Task['tool_arguments']) {
        $Task['tool_arguments']
    } else {
        @{}
    }
    $argCount = if ($toolArgs -is [System.Collections.IDictionary]) { $toolArgs.Count } else { @($toolArgs).Count }

    return @{
        Success     = $true
        Message     = "MCP executor staged for tool '$toolName' ($argCount argument(s)); tool dispatch is wired separately."
        ExitCode    = 0
        tool_name   = $toolName
        arg_count   = $argCount
        run_id      = $RunContext['run_id']
    }
}

Export-ModuleMember -Function Invoke-Executor
