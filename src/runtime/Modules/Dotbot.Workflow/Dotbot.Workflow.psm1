<#
.SYNOPSIS
Workflow manifest utilities — parse workflow.yaml, create tasks, merge MCP servers

.DESCRIPTION
Shared functions used by init-project.ps1, workflow-add.ps1, workflow-run.ps1,
and Invoke-DotbotProcess.ps1 for the multi-workflow system.
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

    $yamlPath = Join-Path $WorkflowDir "workflow.yaml"

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
        # every workflow declares an isolation policy. Default is true:
        # ad-hoc / new authors get isolation by default; authors that genuinely
        # want main-checkout behaviour opt out by setting isolated: false.
        isolated = $true
        requires = @{ env_vars = @(); mcp_servers = @(); cli_tools = @() }
        mcp_servers = @{}
        form = @{}
        domain = @{}
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
            # Normalise isolated → bool. Missing or null = default (true).
            if ($null -eq $manifest['isolated']) {
                $manifest['isolated'] = $true
            } else {
                $manifest['isolated'] = [bool]$manifest['isolated']
            }
            return $manifest
        } catch {
            Write-BotLog -Level Warn -Message "powershell-yaml parse failed, falling back to simple parser" -Exception $_
        }
    }

    # Simple fallback parser (handles flat scalars + type/name/description/extends/isolated)
    Get-Content $yamlPath | ForEach-Object {
        if ($_ -match '^\s*(type|name|description|extends|version|rerun|icon|license|repository|homepage|readme|min_dotbot_version)\s*:\s*(.+)$') {
            $manifest[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
        elseif ($_ -match '^\s*isolated\s*:\s*(true|false)\s*$') {
            $manifest['isolated'] = ($Matches[1] -eq 'true')
        }
    }

    # Normalise isolated → bool. Missing or null = default (true).
    if ($null -eq $manifest['isolated']) {
        $manifest['isolated'] = $true
    } else {
        $manifest['isolated'] = [bool]$manifest['isolated']
    }

    return $manifest
}

function Test-ValidWorkflowDir {
    <#
    .SYNOPSIS
    Returns $true iff $Dir contains a non-empty workflow.yaml.

    .DESCRIPTION
    Single source of truth for "is this folder a real workflow?" Use before
    calling Read-WorkflowManifest at any site that would otherwise treat the
    defaulted manifest of a missing/empty file as if the folder were valid.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Dir
    )

    $yamlPath = Join-Path $Dir "workflow.yaml"
    if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) {
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $yamlPath -ErrorAction Stop
    } catch {
        return $false
    }
    if ($item.Length -eq 0) {
        return $false
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open(
            $yamlPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $reader = [System.IO.StreamReader]::new($stream)
        while ($true) {
            $codepoint = $reader.Read()
            if ($codepoint -lt 0) {
                return $false
            }
            if (-not [char]::IsWhiteSpace([char]$codepoint)) {
                return $true
            }
        }
    } catch {
        return $false
    } finally {
        if ($reader) {
            $reader.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Get-RecipeFolders {
    <#
    .SYNOPSIS
    Recursively discover recipe folders that contain a given marker file.

    .DESCRIPTION
    Walks $BaseDir looking for folders that directly contain $MarkerFile
    (e.g. SKILL.md or AGENT.md). Returns each match as its forward-slash path
    relative to $BaseDir, so nested folders like
    `overrides/group-1/phase-x/SKILL.md` surface as `overrides/group-1/phase-x`.

    Intermediate folders without their own marker file are not surfaced — only
    leaf folders that genuinely contain a recipe show up. Recursion is
    depth-capped so pathological trees don't impact response time.

    Used by /api/workflows/installed in server.ps1 to expose registry-added
    nested skills/agents in the Workflows tab. See issue #406.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BaseDir,

        [Parameter(Mandatory)]
        [string]$MarkerFile,

        [int]$MaxDepth = 4
    )

    if (-not (Test-Path -LiteralPath $BaseDir)) { return @() }

    $results = [System.Collections.Generic.List[string]]::new()
    $rootFull = (Resolve-Path -LiteralPath $BaseDir).ProviderPath.TrimEnd('\','/')

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Path = $rootFull; Depth = 0 })

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $current = $frame.Path
        $depth   = $frame.Depth

        if ($depth -gt 0) {
            $marker = Join-Path $current $MarkerFile
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                $rel = $current.Substring($rootFull.Length).TrimStart('\','/') -replace '\\','/'
                if ($rel) { $results.Add($rel) }
            }
        }

        if ($depth -ge $MaxDepth) { continue }

        $children = Get-ChildItem -LiteralPath $current -Directory -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            $stack.Push(@{ Path = $child.FullName; Depth = $depth + 1 })
        }
    }

    return @($results | Sort-Object)
}

function Get-WorkflowTierRoots {
    <#
    .SYNOPSIS
    Return the (project, framework) workflow tier roots for a project.

    .DESCRIPTION
    Workflows live in two tiers:
      - Project tier:   <project>/.bot/workflows/<name>/
      - Framework tier: <project>/.bot/content/workflows/<name>/

    This helper centralises the path computation so resolvers and discovery
    callers can't drift out of sync. Returns a hashtable with absolute paths;
    the paths are returned even if the directories don't yet exist.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    return @{
        project   = (Join-Path $BotRoot 'workflows')
        framework = (Join-Path (Join-Path $BotRoot 'content') 'workflows')
    }
}

function Find-Workflow {
    <#
    .SYNOPSIS
    Resolve a workflow by name through the two-tier registry.

    .DESCRIPTION
    Resolution order:
      1. <BotRoot>/workflows/<Name>/workflow.yaml         (project tier)
      2. <BotRoot>/content/workflows/<Name>/workflow.yaml (framework tier)
      3. Not found → returns a WorkflowNotFound error record.

    Returns a hashtable with the following shape on success:
        @{ ok = $true; name = <name>; path = <abs dir>; source = 'project'|'framework' }

    On failure:
        @{ ok = $false; reason = 'WorkflowNotFound'; name = <name>;
           message = '<text>'; tried = @(<paths>) }

    A project workflow with the same name as a framework workflow takes
    precedence — this is how authors customise a built-in without forking.

    `path` is the workflow directory (the parent of workflow.yaml), so callers
    can pass it directly to Read-WorkflowManifest / Test-ValidWorkflowDir.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $roots = Get-WorkflowTierRoots -BotRoot $BotRoot
    $tried = @()

    # Tier 1 — project
    $projectDir = Join-Path $roots.project $Name
    $tried += (Join-Path $projectDir 'workflow.yaml')
    if (Test-ValidWorkflowDir -Dir $projectDir) {
        return @{
            ok     = $true
            name   = $Name
            path   = $projectDir
            source = 'project'
        }
    }

    # Tier 2 — framework
    $frameworkDir = Join-Path $roots.framework $Name
    $tried += (Join-Path $frameworkDir 'workflow.yaml')
    if (Test-ValidWorkflowDir -Dir $frameworkDir) {
        return @{
            ok     = $true
            name   = $Name
            path   = $frameworkDir
            source = 'framework'
        }
    }

    return @{
        ok      = $false
        reason  = 'WorkflowNotFound'
        name    = $Name
        message = "Workflow '$Name' not found. Looked in: project tier ($($roots.project)), framework tier ($($roots.framework))."
        tried   = $tried
    }
}

function Discover-Workflows {
    <#
    .SYNOPSIS
    Enumerate every workflow visible to a project, tagged with its tier.

    .DESCRIPTION
    Scans both tier directories, parses each manifest, and returns one entry
    per distinct workflow name. When a name appears in both tiers, the project
    entry wins and its `source` is reported as `project (overrides framework)`
    so the UI / CLI can flag the override.

    Each entry is a hashtable:
        @{
            name        = <string>
            path        = <absolute dir>
            source      = 'project' | 'framework' | 'project (overrides framework)'
            version     = <string>
            description = <string>
            isolated    = <bool>
            icon        = <string>
        }

    Entries are sorted by name. Workflow folders without a valid workflow.yaml
    are silently skipped — Test-ValidWorkflowDir filters them out.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    $roots = Get-WorkflowTierRoots -BotRoot $BotRoot
    $byName = [ordered]@{}

    # Framework tier first so project entries overwrite, leaving the override marker
    foreach ($tier in @(
        @{ key = 'framework'; dir = $roots.framework }
        @{ key = 'project';   dir = $roots.project }
    )) {
        if (-not (Test-Path -LiteralPath $tier.dir)) { continue }

        $children = Get-ChildItem -LiteralPath $tier.dir -Directory -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            if (-not (Test-ValidWorkflowDir -Dir $child.FullName)) { continue }

            $manifest = Read-WorkflowManifest -WorkflowDir $child.FullName
            $name = $child.Name

            if ($tier.key -eq 'project' -and $byName.Contains($name)) {
                # Same-name workflow already seen in framework tier; mark override
                $byName[$name] = @{
                    name        = $name
                    path        = $child.FullName
                    source      = 'project (overrides framework)'
                    version     = if ($manifest.version) { $manifest.version } else { '' }
                    description = if ($manifest.description) { $manifest.description } else { '' }
                    isolated    = [bool]$manifest.isolated
                    icon        = if ($manifest.icon) { $manifest.icon } else { '' }
                }
                continue
            }

            $byName[$name] = @{
                name        = $name
                path        = $child.FullName
                source      = $tier.key
                version     = if ($manifest.version) { $manifest.version } else { '' }
                description = if ($manifest.description) { $manifest.description } else { '' }
                isolated    = [bool]$manifest.isolated
                icon        = if ($manifest.icon) { $manifest.icon } else { '' }
            }
        }
    }

    return @($byName.Values | Sort-Object { $_.name })
}

function Get-ActiveWorkflowManifest {
    <#
    .SYNOPSIS
    Resolve the workflow manifest for the active workflow in a project.

    .DESCRIPTION
    Returns the manifest for the workflow named in settings.workflow when
    present, otherwise the alphabetically-first installed workflow under
    .bot/content/workflows/. Returns $null if no workflow is installed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    # settings.workflow now resolves through Find-Workflow so a
    # project-tier override is honoured before falling back to the framework
    # tier. The alphabetic-first fallback uses Discover-Workflows for the same
    # reason — project entries shadow framework entries in the enumeration.
    try {
        $settingsLoaderPath = Join-Path (Split-Path -Parent $PSScriptRoot) "Dotbot.Settings" "Dotbot.Settings.psm1"
        if ((Test-Path $settingsLoaderPath) -and -not (Get-Module Dotbot.Settings)) {
            Import-Module $settingsLoaderPath -DisableNameChecking -Global
        }
        if (Get-Command Get-MergedSettings -ErrorAction SilentlyContinue) {
            $merged = Get-MergedSettings -BotRoot $BotRoot
            $activeName = if ($merged.PSObject.Properties['workflow']) { $merged.workflow } else { $null }
            if ($activeName) {
                $resolved = Find-Workflow -BotRoot $BotRoot -Name $activeName
                if ($resolved.ok) {
                    return Read-WorkflowManifest -WorkflowDir $resolved.path
                }
            }
        }
    } catch {
        # Fall through to alphabetic-first behaviour.
    }

    $first = Discover-Workflows -BotRoot $BotRoot | Select-Object -First 1
    if ($first) {
        return Read-WorkflowManifest -WorkflowDir $first.path
    }

    return $null
}

function Get-ManifestEntryField {
    param([object]$Entry, [string]$Field)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) { return $Entry[$Field] }
    return $Entry.$Field
}

function Format-ManifestEntryForError {
    <#
    .SYNOPSIS
    Render a manifest entry as a compact "{ key: value, ... }" string for error messages.
    #>
    param([object]$Entry)
    if ($null -eq $Entry) { return '<null>' }
    if ($Entry -is [System.Collections.IDictionary]) {
        $pairs = @()
        foreach ($k in $Entry.Keys) {
            $v = $Entry[$k]
            $vRendered = if ($null -eq $v) { 'null' } elseif ($v -is [string]) { '"' + $v + '"' } else { [string]$v }
            $pairs += "$k`: $vRendered"
        }
        return '{ ' + ($pairs -join ', ') + ' }'
    }
    $pairs = @()
    foreach ($p in $Entry.PSObject.Properties) {
        $vRendered = if ($null -eq $p.Value) { 'null' } elseif ($p.Value -is [string]) { '"' + $p.Value + '"' } else { [string]$p.Value }
        $pairs += "$($p.Name): $vRendered"
    }
    return '{ ' + ($pairs -join ', ') + ' }'
}

function Test-WorkflowManifestSchema {
    <#
    .SYNOPSIS
    Validate a parsed workflow manifest against the requires.* schema.

    .DESCRIPTION
    Returns an array of human-readable error strings — one per malformed entry.
    Empty array means the manifest is valid for the requires.* sections.

    Validates that every entry in:
      - requires.env_vars     has a non-empty 'var' field
      - requires.mcp_servers  has a non-empty 'name' field
      - requires.cli_tools    has a non-empty 'name' field

    Used at install time by `dotbot init` and `dotbot workflow add` to surface
    schema mistakes before any scaffolding runs, so the author gets a clear
    error at the point they can act on it instead of a null-key crash from
    New-EnvLocalScaffold or a silently-dropped preflight check at runtime.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,

        [string]$WorkflowName
    )

    $errors = @()
    if (-not $WorkflowName) {
        $WorkflowName = Get-ManifestEntryField -Entry $Manifest -Field 'name'
        if (-not $WorkflowName) { $WorkflowName = '<unknown>' }
    }

    $requires = Get-ManifestEntryField -Entry $Manifest -Field 'requires'
    if (-not $requires) { return @() }

    # env_vars: each entry must have 'var'
    $envVars = Get-ManifestEntryField -Entry $requires -Field 'env_vars'
    if ($envVars) {
        $i = 0
        foreach ($ev in @($envVars)) {
            $varName = Get-ManifestEntryField -Entry $ev -Field 'var'
            if (-not $varName) {
                $rendered = Format-ManifestEntryForError -Entry $ev
                $errors += @"
env_vars entry [$i] in workflow '$WorkflowName' is missing the required 'var' field.
Entry: $rendered
Expected schema: { var: <IDENTIFIER>, name: <DISPLAY NAME>, message: <TEXT>, hint: <TEXT> }
Note: 'var' is the env var identifier (e.g. GITHUB_TOKEN). 'name' is the human-readable label (e.g. "GitHub Personal Access Token").
"@
            }
            $i++
        }
    }

    # mcp_servers: each entry must have 'name'
    $mcpServers = Get-ManifestEntryField -Entry $requires -Field 'mcp_servers'
    if ($mcpServers) {
        $i = 0
        foreach ($ms in @($mcpServers)) {
            $srvName = Get-ManifestEntryField -Entry $ms -Field 'name'
            if (-not $srvName) {
                $rendered = Format-ManifestEntryForError -Entry $ms
                $errors += @"
mcp_servers entry [$i] in workflow '$WorkflowName' is missing the required 'name' field.
Entry: $rendered
Expected schema: { name: <SERVER NAME>, message: <TEXT>, hint: <TEXT> }
"@
            }
            $i++
        }
    }

    # cli_tools: each entry must have 'name'
    $cliTools = Get-ManifestEntryField -Entry $requires -Field 'cli_tools'
    if ($cliTools) {
        $i = 0
        foreach ($ct in @($cliTools)) {
            $toolName = Get-ManifestEntryField -Entry $ct -Field 'name'
            if (-not $toolName) {
                $rendered = Format-ManifestEntryForError -Entry $ct
                $errors += @"
cli_tools entry [$i] in workflow '$WorkflowName' is missing the required 'name' field.
Entry: $rendered
Expected schema: { name: <TOOL NAME>, message: <TEXT>, hint: <TEXT> }
"@
            }
            $i++
        }
    }

    # Lint: per-task skip_worktree is gone. Isolation is a workflow-level
    # property now. Tasks that carry the old field would have varying isolation
    # within a single run, which the new model forbids.
    $tasks = Get-ManifestEntryField -Entry $Manifest -Field 'tasks'
    if ($tasks) {
        $i = 0
        foreach ($t in @($tasks)) {
            # Hashtable check covers powershell-yaml's parsed output; PSCustomObject
            # check covers JSON-style manifests.
            $hasSkipWorktree = $false
            if ($t -is [System.Collections.IDictionary]) {
                $hasSkipWorktree = $t.Contains('skip_worktree')
            } elseif ($t.PSObject -and $t.PSObject.Properties['skip_worktree']) {
                $hasSkipWorktree = $true
            }
            if ($hasSkipWorktree) {
                $taskName = Get-ManifestEntryField -Entry $t -Field 'name'
                if (-not $taskName) { $taskName = "<unnamed task at index $i>" }
                $errors += @"
task '$taskName' in workflow '$WorkflowName' declares the removed field 'skip_worktree'.
Isolation is a workflow-level property. Set 'isolated: true|false' at the
top of workflow.yaml instead; every task in the run inherits that policy.
"@
            }
            $i++
        }
    }

    return $errors
}

function Convert-ManifestRequiresToPreflightChecks {
    <#
    .SYNOPSIS
    Convert a manifest 'requires' block into flat preflight check objects.

    .DESCRIPTION
    Maps requires.env_vars, requires.mcp_servers, requires.cli_tools into the
    array-of-hashtable format expected by Get-PreflightResults and the UI.

    Throws a clear schema error when an entry is missing its required
    identifier field. Install-time validation via Test-WorkflowManifestSchema
    catches this earlier; this throw is a defense-in-depth backstop for
    hand-edited manifests so the failure is loud instead of silently dropping
    checks (which previously masked auth/401 failures at runtime).
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Requires,

        [string]$WorkflowName = '<unknown>'
    )

    $checks = @()

    # env_vars
    $envVars = if ($Requires -is [System.Collections.IDictionary]) { $Requires['env_vars'] } else { $Requires.env_vars }
    if ($envVars) {
        $i = 0
        foreach ($ev in @($envVars)) {
            $varName = if ($ev -is [System.Collections.IDictionary]) { $ev['var'] } else { $ev.var }
            $name = if ($ev -is [System.Collections.IDictionary]) { $ev['name'] } else { $ev.name }
            $message = if ($ev -is [System.Collections.IDictionary]) { $ev['message'] } else { $ev.message }
            $hint = if ($ev -is [System.Collections.IDictionary]) { $ev['hint'] } else { $ev.hint }
            if (-not $varName) {
                $rendered = Format-ManifestEntryForError -Entry $ev
                throw "env_vars entry [$i] in workflow '$WorkflowName' is missing the required 'var' field.`nEntry: $rendered`nExpected schema: { var: <IDENTIFIER>, name: <DISPLAY NAME>, message: <TEXT>, hint: <TEXT> }`nNote: 'var' is the env var identifier (e.g. GITHUB_TOKEN). 'name' is the human-readable label (e.g. `"GitHub Personal Access Token`")."
            }
            $checks += @{ type = 'env_var'; var = $varName; name = if ($name) { $name } else { $varName }; message = $message; hint = $hint }
            $i++
        }
    }

    # mcp_servers
    $mcpServers = if ($Requires -is [System.Collections.IDictionary]) { $Requires['mcp_servers'] } else { $Requires.mcp_servers }
    if ($mcpServers) {
        $i = 0
        foreach ($ms in @($mcpServers)) {
            $srvName = if ($ms -is [System.Collections.IDictionary]) { $ms['name'] } else { $ms.name }
            $message = if ($ms -is [System.Collections.IDictionary]) { $ms['message'] } else { $ms.message }
            $hint = if ($ms -is [System.Collections.IDictionary]) { $ms['hint'] } else { $ms.hint }
            if (-not $srvName) {
                $rendered = Format-ManifestEntryForError -Entry $ms
                throw "mcp_servers entry [$i] in workflow '$WorkflowName' is missing the required 'name' field.`nEntry: $rendered`nExpected schema: { name: <SERVER NAME>, message: <TEXT>, hint: <TEXT> }"
            }
            $checks += @{ type = 'mcp_server'; name = $srvName; message = $message; hint = $hint }
            $i++
        }
    }

    # cli_tools
    $cliTools = if ($Requires -is [System.Collections.IDictionary]) { $Requires['cli_tools'] } else { $Requires.cli_tools }
    if ($cliTools) {
        $i = 0
        foreach ($ct in @($cliTools)) {
            $toolName = if ($ct -is [System.Collections.IDictionary]) { $ct['name'] } else { $ct.name }
            $message = if ($ct -is [System.Collections.IDictionary]) { $ct['message'] } else { $ct.message }
            $hint = if ($ct -is [System.Collections.IDictionary]) { $ct['hint'] } else { $ct.hint }
            if (-not $toolName) {
                $rendered = Format-ManifestEntryForError -Entry $ct
                throw "cli_tools entry [$i] in workflow '$WorkflowName' is missing the required 'name' field.`nEntry: $rendered`nExpected schema: { name: <TOOL NAME>, message: <TEXT>, hint: <TEXT> }"
            }
            $checks += @{ type = 'cli_tool'; name = $toolName; message = $message; hint = $hint }
            $i++
        }
    }

    return $checks
}

# Import with -Global so Test-ManifestCondition is visible to callers that
# import WorkflowManifest.psm1 from inside a function/scriptblock scope
# (e.g. server.ps1 and task-get-next/script.ps1). Without -Global, the
# imported function ends up in a module scope that is not reached by the
# lookup chain at some HTTP route handler call sites, producing intermittent
# "The term 'Test-ManifestCondition' is not recognized" errors.
# -Force is banned inside child modules per CLAUDE.md; the Get-Module guard
# is the canonical idempotent pattern.
# Test-ManifestCondition is defined later in this file (was previously in a
# separate ManifestCondition module; merged here so the runtime workflow
# domain ships as one unit).

function Ensure-ManifestTaskIds {
    <#
    .SYNOPSIS
    Ensure every task in the manifest tasks array has an id property.

    .DESCRIPTION
    Workflow manifest tasks may omit the id field. This function generates a
    slug-style id from the task name when missing, mutating the original objects
    so downstream code can rely on id being present.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Tasks
    )

    foreach ($t in $Tasks) {
        $existingId = if ($t -is [System.Collections.IDictionary]) { $t['id'] } else { $t.id }
        if (-not $existingId) {
            $taskName = if ($t -is [System.Collections.IDictionary]) { $t['name'] } else { $t.name }
            $genId = ($taskName -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
            if ($t -is [System.Collections.IDictionary]) { $t['id'] = $genId }
            else { $t | Add-Member -NotePropertyName 'id' -NotePropertyValue $genId -Force }
        }
    }
}

function Convert-ManifestTasksToPhases {
    <#
    .SYNOPSIS
    Convert manifest tasks array into phase-compatible objects for the UI.

    .DESCRIPTION
    Transforms each task into a hashtable with id, name, type and optional keys.
    As a side effect, this function calls Ensure-ManifestTaskIds which mutates the
    original input task objects by adding an 'id' property to any task that lacks
    one. Callers should be aware that the $Tasks array items will be modified
    in-place.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Tasks
    )

    Ensure-ManifestTaskIds -Tasks $Tasks

    return @($Tasks | ForEach-Object {
        $task = $_
        $name = if ($task -is [System.Collections.IDictionary]) { $task['name'] } else { $task.name }
        $type = if ($task -is [System.Collections.IDictionary]) { $task['type'] } else { $task.type }
        $optional = if ($task -is [System.Collections.IDictionary]) { $task['optional'] } else { $task.optional }
        @{
            id = if ($task -is [System.Collections.IDictionary]) { $task['id'] } else { $task.id }
            name = $name
            type = if ($type) { $type } else { 'prompt' }
            optional = [bool]$optional
        }
    })
}

function Initialize-WorkflowRun {
    <#
    .SYNOPSIS
    Mint a fresh WorkflowRun: committed run.json + gitignored live status file.

    .DESCRIPTION
    Each `dotbot go` / UI workflow-start mints a new run. Returns a hashtable
    the caller threads into New-WorkflowTask:
      @{
        run_id           = 'wr_AbCd1234'
        workflow_name    = 'start-from-prompt'
        run_dir          = <abs path under workspace/tasks/workflow-runs/<dir>/>
        dir_name         = '<date>-<workflow-slug>-<short_id>'
        short_id         = 4-char derived suffix
        run_record_path  = <run_dir>/run.json
        live_status_path = .control/workflow-runs/<wr_id>.json
        started_at       = ISO-8601 UTC
        name_to_id_map   = @{}    # filled in by New-WorkflowTask
      }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$WorkflowName,
        [string]$StartedBy = 'system',
        [bool]$Isolated = $true,
        $WorkflowPath = $null,
        $WorkflowSource = $null
    )

    $runId     = New-WorkflowRunId
    $startedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $layout    = Get-WorkflowRunLayout -BotRoot $BotRoot -WorkflowName $WorkflowName -RunId $runId -StartedAt $startedAt

    New-Item -ItemType Directory -Path $layout.run_dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $layout.live_status_path) -Force | Out-Null

    $record = New-WorkflowRunRecord `
        -WorkflowName    $WorkflowName `
        -StartedBy       $StartedBy `
        -Isolated        $Isolated `
        -RunId           $runId `
        -StartedAt       $startedAt `
        -WorkflowPath    $WorkflowPath `
        -WorkflowSource  $WorkflowSource

    Write-TaskFileAtomic -Path $layout.run_record_path -Content $record -Depth 20

    $status = New-WorkflowRunStatus -RunId $runId -Status 'running'
    Write-TaskFileAtomic -Path $layout.live_status_path -Content $status -Depth 20

    return [ordered]@{
        run_id           = $runId
        workflow_name    = $WorkflowName
        run_dir          = $layout.run_dir
        dir_name         = $layout.dir_name
        short_id         = $layout.short_id
        run_record_path  = $layout.run_record_path
        live_status_path = $layout.live_status_path
        started_at       = $startedAt
        name_to_id_map   = @{}
    }
}

# Two extension namespaces for non-canonical task fields:
#   extensions.executor — knobs the runner uses to execute the task
#   extensions.workflow — workflow-only metadata declared in the manifest
$script:DotbotWorkflowExtensionKeys = @(
    'outputs_dir', 'min_output_count', 'required_outputs', 'required_outputs_dir',
    'front_matter_docs', 'condition', 'optional', 'steps',
    'applicable_agents', 'applicable_standards', 'needs_interview',
    'human_hours', 'ai_hours', 'max_concurrent', 'timeout', 'retry',
    'on_failure', 'env', 'post_script'
)

function New-WorkflowTask {
    <#
    .SYNOPSIS
    Create a canonical-schema TaskInstance from a manifest task definition,
    inside an existing WorkflowRun directory.

    .DESCRIPTION
    Builds a TaskInstance (t_<id>, provenance pointing at $Run, status
    'todo') and writes it to <run.run_dir>/t_<id>.json.

    Executor knobs (script_path, mcp_tool, mcp_args, prompt, skip_analysis)
    land under extensions.executor. Workflow metadata (outputs_dir,
    condition, optional, …) lands under extensions.workflow.

    Returns @{ id; name; file_path }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Run,                  # output of Initialize-WorkflowRun

        [Parameter(Mandatory)]
        [hashtable]$TaskDef,              # one entry from workflow.yaml tasks[]

        [string]$DefaultCategory = 'workflow',
        [string]$DefaultEffort   = 'XS'
    )

    $runId        = [string]$Run.run_id
    $runDir       = [string]$Run.run_dir
    $workflowName = [string]$Run.workflow_name
    if (-not $runId)        { throw "New-WorkflowTask: Run.run_id is required" }
    if (-not $runDir)       { throw "New-WorkflowTask: Run.run_dir is required" }
    if (-not $workflowName) { throw "New-WorkflowTask: Run.workflow_name is required" }

    $name = $TaskDef['name']
    if (-not $name) { throw "New-WorkflowTask: TaskDef.name is required" }

    $type = if ($TaskDef['type']) { [string]$TaskDef['type'] } else { 'prompt' }

    # task_gen + workflow:<*.md> is a legacy spelling of prompt_template
    # with the prompt path declared via the workflow field.
    $promptFromWorkflow = $null
    if ($type -eq 'task_gen' -and -not $TaskDef['script_path'] -and -not $TaskDef['script'] `
            -and $TaskDef['workflow'] -and ([string]$TaskDef['workflow'] -match '\.md$')) {
        $type = 'prompt_template'
        $promptFromWorkflow = "recipes/prompts/$([string]$TaskDef['workflow'])"
    }

    # Manifest deps are declared by name; resolve to canonical task IDs via
    # Run.name_to_id_map. Unresolved names land in
    # extensions.workflow.unresolved_dependencies as a diagnostic.
    $declaredDeps = @()
    if     ($TaskDef['depends_on'])   { $declaredDeps = @($TaskDef['depends_on']   | Where-Object { $_ -and $_ -ne '' }) }
    elseif ($TaskDef['dependencies']) { $declaredDeps = @($TaskDef['dependencies'] | Where-Object { $_ -and $_ -ne '' }) }

    $nameMap = $Run.name_to_id_map
    if (-not $nameMap) { $nameMap = @{} }
    $deps = @()
    $unresolved = @()
    foreach ($d in $declaredDeps) {
        $dStr = [string]$d
        if (Test-TaskId -Id $dStr) {
            $deps += $dStr
        } elseif ($nameMap.ContainsKey($dStr)) {
            $deps += $nameMap[$dStr]
        } else {
            $unresolved += $dStr
        }
    }

    $priorityRaw = $TaskDef['priority']
    $priority = if ($null -ne $priorityRaw -and "$priorityRaw" -ne '') { $priorityRaw } else { 50 }

    # Build the executor and workflow extension bags. Only non-empty values
    # land in the bag to keep the JSON clean.
    $executorBag = @{}
    $scriptPath = if ($TaskDef['script_path']) { $TaskDef['script_path'] } else { $TaskDef['script'] }
    if ($scriptPath)                                { $executorBag['script_path'] = [string]$scriptPath }
    if ($promptFromWorkflow)                        { $executorBag['prompt']      = $promptFromWorkflow }
    elseif ($TaskDef['prompt'])                     { $executorBag['prompt']      = [string]$TaskDef['prompt'] }
    if ($TaskDef['mcp_tool'])                       { $executorBag['mcp_tool']    = [string]$TaskDef['mcp_tool'] }
    if ($TaskDef['mcp_args'] -and $TaskDef['mcp_args'].Count -gt 0) { $executorBag['mcp_args'] = $TaskDef['mcp_args'] }
    $defaultSkipAnalysis = ($type -ne 'prompt')
    $skipAnalysis = if ($null -ne $TaskDef['skip_analysis']) { [bool]$TaskDef['skip_analysis'] } else { $defaultSkipAnalysis }
    $executorBag['skip_analysis'] = $skipAnalysis

    $workflowBag = @{}
    foreach ($k in $script:DotbotWorkflowExtensionKeys) {
        if ($null -eq $TaskDef[$k]) { continue }
        $v = $TaskDef[$k]
        if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { continue }
        if (($v -is [System.Collections.IList]) -and (@($v).Count -eq 0)) { continue }
        if (($v -is [System.Collections.IDictionary]) -and ($v.Count -eq 0)) { continue }
        $workflowBag[$k] = $v
    }
    if ($unresolved.Count -gt 0) {
        $workflowBag['unresolved_dependencies'] = @($unresolved)
    }

    # Coerce numerics for type-safety on downstream reads.
    foreach ($intField in @('min_output_count','max_concurrent','timeout','retry')) {
        if ($workflowBag.ContainsKey($intField)) { $workflowBag[$intField] = [int]$workflowBag[$intField] }
    }
    if ($workflowBag.ContainsKey('optional')) { $workflowBag['optional'] = [bool]$workflowBag['optional'] }

    $extensions = @{ executor = $executorBag }
    if ($workflowBag.Count -gt 0) { $extensions['workflow'] = $workflowBag }

    $taskId = New-TaskId

    $outputs = @()
    if ($TaskDef['outputs']) { $outputs = @($TaskDef['outputs'] | Where-Object { $_ -and $_ -ne '' }) }

    $acceptance = @()
    if ($TaskDef['acceptance_criteria']) { $acceptance = @($TaskDef['acceptance_criteria'] | Where-Object { $_ -and $_ -ne '' }) }

    $description = if ($TaskDef['description']) { [string]$TaskDef['description'] } else { $name }
    $effort      = if ($TaskDef['effort'])       { [string]$TaskDef['effort'] }      else { $DefaultEffort }
    $category    = if ($TaskDef['category'])     { [string]$TaskDef['category'] }     else { $DefaultCategory }

    $task = New-TaskInstance `
        -Id $taskId `
        -Name $name `
        -Description $description `
        -Status 'todo' `
        -Type $type `
        -Category $category `
        -Priority $priority `
        -Effort $effort `
        -Dependencies ([string[]]$deps) `
        -AcceptanceCriteria ([string[]]$acceptance) `
        -Outputs ([string[]]$outputs) `
        -Provenance @{
            workflow        = $workflowName
            run_id          = $runId
            definition_name = $name
            expanded_by     = 'workflow-expansion'
        } `
        -Extensions $extensions `
        -UpdatedBy 'workflow-bootstrap'

    $filePath = Join-Path $runDir "$taskId.json"
    Write-TaskFileAtomic -Path $filePath -Content $task -Depth 20 -TaskId $taskId

    # Record name → id (plus slug alias) so later tasks can resolve
    # depends-on by name.
    if (-not $Run.name_to_id_map) { $Run['name_to_id_map'] = @{} }
    $Run.name_to_id_map[$name] = $taskId
    $slug = (($name -replace '[^\w\s-]','' -replace '\s+','-').ToLowerInvariant())
    if ($slug -and -not $Run.name_to_id_map.ContainsKey($slug)) {
        $Run.name_to_id_map[$slug] = $taskId
    }

    return @{ id = $taskId; name = $name; file_path = $filePath }
}

function Find-WorkflowRunDir {
    <#
    .SYNOPSIS
    Resolve a wr_<id> to its on-disk run_dir under workspace/tasks/workflow-runs/.

    .DESCRIPTION
    Derive the 4-char short ID via Get-ShortId, scan workflow-runs/* for
    directories ending in -<short>, and confirm by parsing the candidate's
    run.json and matching run_id. Returns the absolute path or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$RunId
    )
    if (-not (Test-WorkflowRunId -Id $RunId)) { return $null }
    $short = Get-ShortId -Id $RunId
    $runsRoot = Join-Path $BotRoot (Join-Path 'workspace' (Join-Path 'tasks' 'workflow-runs'))
    if (-not (Test-Path -LiteralPath $runsRoot)) { return $null }
    foreach ($candidate in (Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -like "*-$short" })) {
        $runJson = Join-Path $candidate.FullName 'run.json'
        if (-not (Test-Path -LiteralPath $runJson)) { continue }
        try {
            $parsed = Get-Content -LiteralPath $runJson -Raw | ConvertFrom-Json -AsHashtable
            if ($parsed.run_id -eq $RunId) { return $candidate.FullName }
        } catch { continue }
    }
    return $null
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
            $existsAlready = $existing.Contains($serverName)
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
    workflow (or is a core server like dotbot, context7, playwright).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$McpJsonPath,

        [Parameter(Mandatory)]
        [string]$WorkflowsDir       # .bot/content/workflows/
    )

    $coreServers = @('dotbot', 'context7', 'playwright')

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

    .DESCRIPTION
    Throws a clear schema error when any entry is missing 'var'. Install-time
    validation via Test-WorkflowManifestSchema catches this earlier; this throw
    is a defense-in-depth backstop replacing the previous null-key crash from
    Hashtable.ContainsKey($null), which gave authors no actionable signal.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EnvLocalPath,

        [Parameter(Mandatory)]
        [array]$EnvVars,            # array of @{ var, name, hint }

        [string]$WorkflowName = '<unknown>'
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
    $i = 0
    foreach ($ev in $EnvVars) {
        $varName = if ($ev -is [System.Collections.IDictionary]) { $ev['var'] } else { $ev.var }
        if (-not $varName) {
            $rendered = Format-ManifestEntryForError -Entry $ev
            throw "env_vars entry [$i] in workflow '$WorkflowName' is missing the required 'var' field.`nEntry: $rendered`nExpected schema: { var: <IDENTIFIER>, name: <DISPLAY NAME>, message: <TEXT>, hint: <TEXT> }`nNote: 'var' is the env var identifier (e.g. GITHUB_TOKEN). 'name' is the human-readable label (e.g. `"GitHub Personal Access Token`")."
        }
        $hint = if ($ev -is [System.Collections.IDictionary]) { $ev['hint'] } else { $ev.hint }
        if (-not $hint) { $hint = "" }
        $displayName = if ($ev -is [System.Collections.IDictionary]) { $ev['name'] } else { $ev.name }
        if (-not $displayName) { $displayName = $varName }

        if ($existing.ContainsKey($varName)) {
            $lines += "$varName=$($existing[$varName])"
        } else {
            if ($hint) { $lines += "# $displayName — $hint" }
            $lines += "$varName="
        }
        $i++
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
            } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to remove item" -Exception $_ }
        }
    }

    return $removed
}

function Test-CanStartRun {
    <#
    .SYNOPSIS
    Decide whether a new WorkflowRun can start given the set of currently active runs.

    .DESCRIPTION
    Pure function. Implements the concurrency rule:

        if NewRun.isolated:           -> OK (isolated runs never conflict)
        for run in ActiveRuns where status == 'running':
            if not run.isolated:      -> Conflict ("Another non-isolated workflow is running")
        -> OK

    The rule has no side effects and does not touch disk. The runtime HTTP
    server consults this function before transitioning a new WorkflowRun
    to 'running' and turns a Conflict result into an HTTP 409.

    .PARAMETER NewRun
    Hashtable or PSCustomObject describing the run being started.
    Must carry an 'isolated' boolean. An 'id' field is used when present
    purely to make the conflict message refer to the new run by name.

    .PARAMETER ActiveRuns
    Array of run records (hashtable / PSCustomObject). Only entries whose
    'status' equals 'running' participate in the decision. Each entry must
    carry an 'isolated' boolean; entries should also carry 'id' and
    (optionally) 'workflow_name' so the conflict message can point at the
    blocking run.

    .OUTPUTS
    Hashtable with shape:
        @{ ok = $true }
            -- start permitted; no blocking run
        @{ ok = $false; reason = 'non_isolated_conflict'; blocking_run_id = 'wr_xxxx'; message = '<text>' }
        -- start blocked; returns this as HTTP 409.

    .EXAMPLE
    Test-CanStartRun -NewRun @{ isolated = $false } -ActiveRuns @(
        @{ id = 'wr_AbCd1234'; isolated = $true; status = 'running' }
    )
    # -> @{ ok = $true }

    .EXAMPLE
    Test-CanStartRun -NewRun @{ isolated = $false } -ActiveRuns @(
        @{ id = 'wr_AbCd1234'; isolated = $false; status = 'running' }
    )
    # -> @{ ok = $false; reason = 'non_isolated_conflict'; blocking_run_id = 'wr_AbCd1234'; ... }
    #>
    param(
        [Parameter(Mandatory)]
        [object]$NewRun,

        [Parameter()]
        [object[]]$ActiveRuns
    )

    $newIsolated = [bool](Get-ManifestEntryField -Entry $NewRun -Field 'isolated')
    if ($newIsolated) {
        return @{ ok = $true }
    }

    if (-not $ActiveRuns) {
        return @{ ok = $true }
    }

    foreach ($run in $ActiveRuns) {
        if ($null -eq $run) { continue }
        $status = Get-ManifestEntryField -Entry $run -Field 'status'
        if ($status -ne 'running') { continue }
        $runIsolated = [bool](Get-ManifestEntryField -Entry $run -Field 'isolated')
        if (-not $runIsolated) {
            $blockingId = Get-ManifestEntryField -Entry $run -Field 'id'
            if (-not $blockingId) { $blockingId = '<unknown>' }
            $blockingWf = Get-ManifestEntryField -Entry $run -Field 'workflow_name'
            $label = if ($blockingWf) { "'$blockingWf' ($blockingId)" } else { $blockingId }
            return @{
                ok              = $false
                reason          = 'non_isolated_conflict'
                blocking_run_id = $blockingId
                message         = "Another non-isolated workflow is running: $label"
            }
        }
    }

    return @{ ok = $true }
}

function Test-GitReadyForIsolation {
    <#
    .SYNOPSIS
    Check whether a project directory satisfies the isolated-run preconditions.

    .DESCRIPTION
    : starting an isolated WorkflowRun requires that the project
    directory is a git repo with at least one commit on the current branch.
    Concretely:
        - <ProjectRoot>/.git must exist (directory or gitlink file — gitlink
          covers the worktree case where .git is a small file pointing to the
          real gitdir).
        - 'git rev-list --count HEAD' must succeed and return > 0.

    On success returns @{ ok = $true }. On failure returns @{ ok = $false;
    reason = 'no_git'|'no_commits'|'git_unavailable'; message = '<text>' }
    where <text> is the user-facing refusal message from the PRD:

        "Isolated workflows require a git repo with at least one commit on the
         base branch. Either initialise git and commit first, or set
         'isolated: false' on this workflow."

    This is a pure check — it neither modifies anything nor talks to a
    network. Dotbot.Worktree's create call also invokes the check before
    allocating a worktree.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $refusalMessage = @(
        "Isolated workflows require a git repo with at least one commit on the base branch."
        "Either initialise git and commit first, or set 'isolated: false' on this workflow."
    ) -join "`n"

    $gitPath = Join-Path $ProjectRoot '.git'
    if (-not (Test-Path -LiteralPath $gitPath)) {
        return @{
            ok      = $false
            reason  = 'no_git'
            message = $refusalMessage
        }
    }

    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitExe) {
        return @{
            ok      = $false
            reason  = 'git_unavailable'
            message = "git CLI is not available on PATH; cannot verify the isolation precondition.`n$refusalMessage"
        }
    }

    $count = $null
    try {
        # -C <dir> so we do not have to push/pop CWD; capture stderr to keep it
        # out of the user-visible output stream when the check is being polled.
        $stdout = & git -C $ProjectRoot rev-list --count HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $stdout) {
            $count = [int]($stdout.ToString().Trim())
        }
    } catch {
        $count = $null
    }

    if (-not $count -or $count -le 0) {
        return @{
            ok      = $false
            reason  = 'no_commits'
            message = $refusalMessage
        }
    }

    return @{ ok = $true }
}

function Test-ManifestCondition {
    <#
    .SYNOPSIS
    Evaluate a gitignore-style path condition against the project root.

    .DESCRIPTION
    Conditions are path patterns resolved from the project root (parent of .bot/).
    - Path present = must exist: ".bot/workspace/product/mission.md"
    - ! prefix = must NOT exist: "!.bot/workspace/product/mission.md"
    - Glob * = directory has matching files: ".git/refs/heads/*"
    - Single string = one condition. Array = AND (all must match).
    - Legacy file_exists: prefix = backward-compat alias (resolves under .bot/).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter()]
        [object]$Condition
    )

    if (-not $Condition) { return $true }

    # Normalize to array
    $rules = if ($Condition -is [array]) { $Condition }
             elseif ($Condition -is [string]) { @($Condition) }
             else { return $true }

    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootWithSep = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    # Windows/macOS are case-insensitive on paths; Linux is case-sensitive.
    $pathComparison = if ($IsLinux) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }

    foreach ($rule in $rules) {
        $rule = "$rule".Trim()
        if (-not $rule) { continue }

        # Legacy compat: strip file_exists: prefix -> resolve under .bot/
        if ($rule -match '^file_exists:(.+)$') {
            $rule = ".bot/$($Matches[1])"
        }

        $negate = $rule.StartsWith('!')
        if ($negate) { $rule = $rule.Substring(1) }

        $fullPath = Join-Path $ProjectRoot $rule

        # Path traversal guard: resolved path must stay within project root.
        # Use boundary-safe comparison (root + separator) with OS-appropriate casing
        # so sibling paths like "C:\projX" can't bypass a "C:\proj" root.
        $resolvedFull = [System.IO.Path]::GetFullPath($fullPath)
        $insideRoot = $resolvedFull.Equals($resolvedRoot, $pathComparison) -or `
                      $resolvedFull.StartsWith($rootWithSep, $pathComparison)
        if (-not $insideRoot) {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Warn -Message "[ManifestCondition] Path traversal blocked: '$rule' resolves outside project root."
            }
            return $false
        }

        $exists = if ($rule -match '\*') {
            @(Resolve-Path $fullPath -ErrorAction SilentlyContinue).Count -gt 0
        } else {
            Test-Path $fullPath
        }

        if ($negate -eq $exists) { return $false }
    }

    return $true
}

Export-ModuleMember -Function @(
    'Read-WorkflowManifest'
    'Test-ValidWorkflowDir'
    'Get-RecipeFolders'
    'Get-ActiveWorkflowManifest'
    'Get-WorkflowTierRoots'
    'Find-Workflow'
    'Discover-Workflows'
    'Get-ManifestEntryField'
    'Format-ManifestEntryForError'
    'Test-WorkflowManifestSchema'
    'Convert-ManifestRequiresToPreflightChecks'
    'Ensure-ManifestTaskIds'
    'Convert-ManifestTasksToPhases'
    'New-WorkflowTask'
    'Initialize-WorkflowRun'
    'Find-WorkflowRunDir'
    'Merge-McpServers'
    'Remove-OrphanMcpServers'
    'New-EnvLocalScaffold'
    'Clear-WorkflowTasks'
    'Test-ManifestCondition'
    'Test-CanStartRun'
    'Test-GitReadyForIsolation'

    # Defined in nested modules under Private/, re-exported here so the
    # manifest sees them.
    'Get-TaskDefinitionFields'
    'Get-TaskDefinitionRemovedFields'
    'Test-TaskDefinition'
    'Assert-TaskDefinition'
    'Get-WorkflowRunSchemaVersion'
    'Get-WorkflowRunRecordFields'
    'Get-WorkflowRunStatusFields'
    'Get-WorkflowRunStatuses'
    'Test-WorkflowRunRecord'
    'Assert-WorkflowRunRecord'
    'Test-WorkflowRunStatus'
    'Assert-WorkflowRunStatus'
    'New-WorkflowRunRecord'
    'New-WorkflowRunStatus'
)
