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
- Imports `Test-Helpers.psm1` via `$env:DOTBOT_TEST_HELPERS` (set by the test runner)
- Dot-sources `script.ps1` and calls `Invoke-YourToolName` directly
- Uses `Assert-True` / `Assert-Equal` for assertions
- Run via `pwsh tests/Test-ToolLocal.ps1` (creates temp project automatically)

**Template:**
```powershell
# Test your-tool-name tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$result = Invoke-YourToolName -Arguments @{
    input1 = 'test'
    input2 = 42
}

Assert-True -Name "your-tool-name: returns success" `
    -Condition ($result.success -eq $true) `
    -Message "Got: $($result.message)"

Assert-Equal -Name "your-tool-name: output matches" `
    -Expected 'expected value' `
    -Actual $result.output

$allPassed = Write-TestSummary -LayerName "your-tool-name"
if (-not $allPassed) { exit 1 }
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
```powershell
# Run all tool-local tests
pwsh tests/Test-ToolLocal.ps1

# Run full test suite (includes tool-local tests)
pwsh tests/Run-Tests.ps1
```

