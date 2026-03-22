# Adding New Tools

## Quick Start
1. Create folder: `.bot/mcp/tools/your-tool-name/`
2. Add three files: `script.ps1`, `metadata.yaml`, `test.ps1`
3. Server auto-discovers and loads the tool

## File Structure
```
.bot/mcp/tools/your-tool-name/
├── script.ps1      # Implementation
├── metadata.yaml   # Schema and description
└── test.ps1        # Tests
```

## script.ps1
- Must contain function named `Invoke-YourToolName` (PascalCase)
- Function receives `[hashtable]$Arguments` parameter
- Return hashtable with result data
- Helper functions available: `Get-DateFromString`, `Write-JsonRpcResponse`, `Write-JsonRpcError`

**Template:**
```powershell
function Invoke-YourToolName {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $input1 = $Arguments['input1']
    $input2 = $Arguments['input2']
    
    # Process
    $result = # your logic here
    
    # Return hashtable
    return @{
        output = $result
        metadata = "additional info"
    }
}
```

## metadata.yaml
- `name`: tool name in snake_case (e.g., `your_tool_name`)
- `description`: clear one-line description
- `inputSchema`: JSON Schema format for parameters

**Template:**
```yaml
name: your_tool_name
description: Brief description of what this tool does
inputSchema:
  type: object
  properties:
    input1:
      type: string
      description: Description of input1
    input2:
      type: integer
      description: Description of input2
  required: [input1]
```

## test.ps1
- Receives `$Process` parameter (running MCP server)
- Use `Send-McpRequest` helper function
- Write test output with `Write-Host`

**Template:**
```powershell
#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [System.Diagnostics.Process]$Process
)

. "$PSScriptRoot\..\..\dotbot-mcp-helpers.ps1"

function Send-McpRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Request,
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )
    
    $json = $Request | ConvertTo-Json -Depth 10 -Compress
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
    Start-Sleep -Milliseconds 100
    $response = $Process.StandardOutput.ReadLine()
    
    if ($response) {
        return $response | ConvertFrom-Json
    }
    return $null
}

Write-Host "Test: Your tool description" -ForegroundColor Yellow
$response = Send-McpRequest -Process $Process -Request @{
    jsonrpc = '2.0'
    id = 1
    method = 'tools/call'
    params = @{
        name = 'your_tool_name'
        arguments = @{
            input1 = 'test'
            input2 = 42
        }
    }
}
$result = $response.result.content[0].text | ConvertFrom-Json
Write-Host "✓ Result: $($result.output)" -ForegroundColor Green
```

## Task Types
Tasks support a `type` field that controls how the runner executes them:
- `prompt` (default) — sends description to Claude CLI
- `script` — runs a `.ps1` file directly (requires `script_path`)
- `mcp` — calls an MCP tool function (requires `mcp_tool`, optional `mcp_args`)
- `task_gen` — runs a script that creates more tasks (requires `script_path`)

Non-prompt tasks automatically skip analysis and worktree creation.

## Naming Convention
- Folder: `kebab-case` (e.g., `get-current-datetime`)
- YAML name: `snake_case` (e.g., `get_current_datetime`)
- Function: `PascalCase` with `Invoke-` prefix (e.g., `Invoke-GetCurrentDateTime`)

## Example: Existing Tool
See `.bot/mcp/tools/get-current-datetime/` for a complete working example.

## Testing
Run individual tool test:
```powershell
# Start server manually then source the test
. .\.bot\mcp\tools\your-tool-name\test.ps1 -Process $serverProcess
```

Or run full test suite (after implementing test runner).

