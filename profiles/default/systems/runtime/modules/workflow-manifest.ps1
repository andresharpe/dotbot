<#
.SYNOPSIS
Workflow manifest utilities — parse workflow.yaml, create tasks, merge MCP servers

.DESCRIPTION
Shared functions used by init-project.ps1, workflow-add.ps1, workflow-run.ps1,
and launch-process.ps1 for the multi-workflow system.
#>

function Read-WorkflowManifest {
    <#
    .SYNOPSIS
    Parse a workflow.yaml file into a hashtable.

    .DESCRIPTION
    Lightweight YAML parser that handles the workflow manifest schema.
    Handles scalars, simple lists (inline [...] and block - item), and
    nested objects (author, requires, form, mcp_servers, tasks).
    Falls back to profile.yaml if workflow.yaml not found.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowDir
    )

    # Prefer workflow.yaml, fall back to profile.yaml
    $yamlPath = Join-Path $WorkflowDir "workflow.yaml"
    if (-not (Test-Path $yamlPath)) {
        $yamlPath = Join-Path $WorkflowDir "profile.yaml"
    }

    $manifest = @{
        name = (Split-Path $WorkflowDir -Leaf)
        type = "workflow"
        version = "1.0"
        description = ""
        author = @{}
        icon = ""
        license = ""
        tags = @()
        categories = @()
        repository = ""
        homepage = ""
        readme = ""
        min_dotbot_version = ""
        rerun = "fresh"
        requires = @{ env_vars = @() }
        mcp_servers = @{}
        form = @{}
        tasks = @()
    }

    if (-not (Test-Path $yamlPath)) {
        return $manifest
    }

    # Use powershell-yaml module if available for full parsing
    $yamlModule = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
    if ($yamlModule) {
        try {
            $raw = Get-Content $yamlPath -Raw
            $parsed = ConvertFrom-Yaml $raw -Ordered
            if ($parsed) {
                # Map parsed YAML to manifest structure
                foreach ($key in @($parsed.Keys)) {
                    $manifest[$key] = $parsed[$key]
                }
            }
            return $manifest
        } catch {
            Write-Warning "powershell-yaml parse failed, falling back to simple parser: $_"
        }
    }

    # Simple fallback parser (handles flat scalars + type/name/description/extends)
    Get-Content $yamlPath | ForEach-Object {
        if ($_ -match '^\s*(type|name|description|extends|version|rerun|icon|license|repository|homepage|readme|min_dotbot_version)\s*:\s*(.+)$') {
            $manifest[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }

    return $manifest
}

function New-WorkflowTask {
    <#
    .SYNOPSIS
    Create a task JSON file from a manifest task definition.

    .DESCRIPTION
    Writes a task JSON file into the shared task queue (workspace/tasks/todo/).
    Sets the workflow field for filtering. Script paths are stored relative to
    the workflow directory.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProjectBotDir,          # .bot/ directory

        [Parameter(Mandatory)]
        [string]$WorkflowName,           # e.g. "iwg-bs-scoring"

        [Parameter(Mandatory)]
        [hashtable]$TaskDef,             # from workflow.yaml tasks array

        [string]$Category = "workflow",
        [string]$Effort = "XS"
    )

    $tasksDir = Join-Path $ProjectBotDir "workspace\tasks\todo"
    if (-not (Test-Path $tasksDir)) { New-Item -Path $tasksDir -ItemType Directory -Force | Out-Null }

    $id = [System.Guid]::NewGuid().ToString()
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Extract fields — align with task-create MCP tool schema
    $name        = $TaskDef['name']
    $type        = if ($TaskDef['type']) { $TaskDef['type'] } else { 'prompt' }
    $priority    = if ($TaskDef['priority']) { [int]$TaskDef['priority'] } else { 50 }
    $description = if ($TaskDef['description']) { $TaskDef['description'] } else { $name }
    $effort      = if ($TaskDef['effort']) { $TaskDef['effort'] } else { $Effort }
    $category    = if ($TaskDef['category']) { $TaskDef['category'] } else { $Category }
    $scriptPath  = if ($TaskDef['script']) { $TaskDef['script'] } else { $TaskDef['script_path'] }
    $mcpTool     = $TaskDef['mcp_tool']
    $mcpArgs     = $TaskDef['mcp_args']

    # Dependencies: convert from manifest format (string names)
    $deps = @()
    if ($TaskDef['depends_on']) { $deps = @($TaskDef['depends_on']) }
    elseif ($TaskDef['dependencies']) { $deps = @($TaskDef['dependencies']) }

    # Boolean fields with type-aware defaults
    $skipAnalysis = if ($null -ne $TaskDef['skip_analysis']) { [bool]$TaskDef['skip_analysis'] } else { $type -ne 'prompt' }
    $skipWorktree = if ($null -ne $TaskDef['skip_worktree']) { [bool]$TaskDef['skip_worktree'] } else { $type -ne 'prompt' }

    $task = [ordered]@{
        id                    = $id
        name                  = $name
        description           = $description
        category              = $category
        priority              = $priority
        effort                = $effort
        status                = "todo"
        type                  = $type
        workflow              = $WorkflowName
        dependencies          = $deps
        skip_analysis         = $skipAnalysis
        skip_worktree         = $skipWorktree
        created_at            = $now
        updated_at            = $now
        completed_at          = $null
    }

    # Optional fields — only set if declared (keeps task JSON clean)
    if ($scriptPath)                           { $task["script_path"] = $scriptPath }
    if ($mcpTool)                              { $task["mcp_tool"] = $mcpTool }
    if ($mcpArgs -and $mcpArgs.Count -gt 0)    { $task["mcp_args"] = $mcpArgs }
    if ($TaskDef['acceptance_criteria'])        { $task["acceptance_criteria"] = @($TaskDef['acceptance_criteria']) }
    if ($TaskDef['steps'])                     { $task["steps"] = @($TaskDef['steps']) }
    if ($TaskDef['applicable_agents'])         { $task["applicable_agents"] = @($TaskDef['applicable_agents']) }
    if ($TaskDef['applicable_standards'])       { $task["applicable_standards"] = @($TaskDef['applicable_standards']) }
    if ($TaskDef['needs_interview'])            { $task["needs_interview"] = [bool]$TaskDef['needs_interview'] }
    if ($TaskDef['working_dir'])               { $task["working_dir"] = $TaskDef['working_dir'] }
    if ($TaskDef['human_hours'])               { $task["human_hours"] = $TaskDef['human_hours'] }
    if ($TaskDef['ai_hours'])                  { $task["ai_hours"] = $TaskDef['ai_hours'] }
    if ($TaskDef['prompt'])                    { $task["prompt"] = $TaskDef['prompt'] }
    if ($TaskDef['max_concurrent'])            { $task["max_concurrent"] = [int]$TaskDef['max_concurrent'] }
    if ($TaskDef['timeout'])                   { $task["timeout"] = [int]$TaskDef['timeout'] }
    if ($TaskDef['retry'])                     { $task["retry"] = [int]$TaskDef['retry'] }
    if ($TaskDef['on_failure'])                { $task["on_failure"] = $TaskDef['on_failure'] }
    if ($TaskDef['condition'])                 { $task["condition"] = $TaskDef['condition'] }
    if ($TaskDef['outputs'])                   { $task["outputs"] = @($TaskDef['outputs']) }
    if ($TaskDef['env'])                       { $task["env"] = $TaskDef['env'] }

    $slug = ($name -replace '[^\w\s-]', '' -replace '\s+', '-').ToLower()
    if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50) }
    $fileName = "$slug-$($id.Split('-')[0]).json"
    $filePath = Join-Path $tasksDir $fileName

    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8

    return @{ id = $id; name = $name; file = $fileName }
}

function Merge-McpServers {
    <#
    .SYNOPSIS
    Merge workflow's mcp_servers into the project's .mcp.json.

    .DESCRIPTION
    For each server declared in the workflow manifest, adds it to .mcp.json
    if a server with that name doesn't already exist. Skips existing entries.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$McpJsonPath,

        [Parameter(Mandatory)]
        [object]$WorkflowServers    # hashtable or PSCustomObject from manifest
    )

    $mcpConfig = @{ mcpServers = [ordered]@{} }
    if (Test-Path $McpJsonPath) {
        try {
            $mcpConfig = Get-Content $McpJsonPath -Raw | ConvertFrom-Json
            if (-not $mcpConfig.mcpServers) {
                $mcpConfig | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([ordered]@{}) -Force
            }
        } catch {
            $mcpConfig = @{ mcpServers = [ordered]@{} }
        }
    }

    $existing = $mcpConfig.mcpServers
    $added = 0

    # Handle both hashtable and PSCustomObject
    $serverEntries = if ($WorkflowServers -is [System.Collections.IDictionary]) {
        $WorkflowServers.GetEnumerator()
    } elseif ($WorkflowServers.PSObject) {
        $WorkflowServers.PSObject.Properties
    } else {
        @()
    }

    foreach ($entry in $serverEntries) {
        $serverName = $entry.Name
        $serverDef = $entry.Value

        # Skip if already exists
        $existsAlready = $false
        if ($existing -is [PSCustomObject]) {
            $existsAlready = $existing.PSObject.Properties.Name -contains $serverName
        } elseif ($existing -is [System.Collections.IDictionary]) {
            $existsAlready = $existing.ContainsKey($serverName)
        }

        if (-not $existsAlready) {
            if ($existing -is [PSCustomObject]) {
                $existing | Add-Member -NotePropertyName $serverName -NotePropertyValue $serverDef -Force
            } else {
                $existing[$serverName] = $serverDef
            }
            $added++
        }
    }

    if ($added -gt 0) {
        $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $McpJsonPath -Encoding UTF8
    }

    return $added
}

function Remove-OrphanMcpServers {
    <#
    .SYNOPSIS
    Remove MCP servers from .mcp.json that no installed workflow claims.

    .DESCRIPTION
    Reads all installed workflow manifests, collects their declared servers,
    and removes any server from .mcp.json that isn't claimed by at least one
    workflow (or is a core server like dotbot, context7, playwright, serena).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$McpJsonPath,

        [Parameter(Mandatory)]
        [string]$WorkflowsDir       # .bot/workflows/
    )

    $coreServers = @('dotbot', 'context7', 'playwright', 'serena')

    if (-not (Test-Path $McpJsonPath)) { return 0 }

    # Collect all servers claimed by installed workflows
    $claimed = @{}
    if (Test-Path $WorkflowsDir) {
        Get-ChildItem $WorkflowsDir -Directory | ForEach-Object {
            $manifest = Read-WorkflowManifest -WorkflowDir $_.FullName
            if ($manifest.mcp_servers) {
                $servers = if ($manifest.mcp_servers -is [System.Collections.IDictionary]) {
                    $manifest.mcp_servers.Keys
                } elseif ($manifest.mcp_servers.PSObject) {
                    $manifest.mcp_servers.PSObject.Properties.Name
                } else { @() }
                foreach ($s in $servers) { $claimed[$s] = $true }
            }
        }
    }

    # Add core servers as always-claimed
    foreach ($s in $coreServers) { $claimed[$s] = $true }

    $mcpConfig = Get-Content $McpJsonPath -Raw | ConvertFrom-Json
    $existing = $mcpConfig.mcpServers
    $removed = 0

    if ($existing -is [PSCustomObject]) {
        foreach ($name in @($existing.PSObject.Properties.Name)) {
            if (-not $claimed.ContainsKey($name)) {
                $existing.PSObject.Properties.Remove($name)
                $removed++
            }
        }
    }

    if ($removed -gt 0) {
        $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $McpJsonPath -Encoding UTF8
    }

    return $removed
}

function New-EnvLocalScaffold {
    <#
    .SYNOPSIS
    Create or update .env.local with required variables from workflow manifests.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EnvLocalPath,

        [Parameter(Mandatory)]
        [array]$EnvVars             # array of @{ var, name, hint }
    )

    # Read existing values
    $existing = @{}
    if (Test-Path $EnvLocalPath) {
        Get-Content $EnvLocalPath | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                $existing[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
    }

    # Build content: preserve existing values, add missing with hints
    $lines = @()
    foreach ($ev in $EnvVars) {
        $varName = $ev.var
        if (-not $varName) { $varName = $ev['var'] }
        $hint = if ($ev.hint) { $ev.hint } elseif ($ev['hint']) { $ev['hint'] } else { "" }
        $displayName = if ($ev.name) { $ev.name } elseif ($ev['name']) { $ev['name'] } else { $varName }

        if ($existing.ContainsKey($varName)) {
            $lines += "$varName=$($existing[$varName])"
        } else {
            if ($hint) { $lines += "# $displayName — $hint" }
            $lines += "$varName="
        }
    }

    # Preserve any extra vars not in the manifest
    foreach ($key in $existing.Keys) {
        $declared = $EnvVars | Where-Object { ($_.var -eq $key) -or ($_['var'] -eq $key) }
        if (-not $declared) {
            $lines += "$key=$($existing[$key])"
        }
    }

    Set-Content -Path $EnvLocalPath -Value ($lines -join "`n") -Encoding UTF8
}

function Clear-WorkflowTasks {
    <#
    .SYNOPSIS
    Remove all tasks belonging to a specific workflow from all task queues.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TasksBaseDir,       # .bot/workspace/tasks

        [Parameter(Mandatory)]
        [string]$WorkflowName
    )

    $removed = 0
    foreach ($status in @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped', 'cancelled', 'split')) {
        $dir = Join-Path $TasksBaseDir $status
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Filter "*.json" -File | ForEach-Object {
            try {
                $content = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($content.workflow -eq $WorkflowName) {
                    Remove-Item $_.FullName -Force
                    $removed++
                }
            } catch {}
        }
    }

    return $removed
}
