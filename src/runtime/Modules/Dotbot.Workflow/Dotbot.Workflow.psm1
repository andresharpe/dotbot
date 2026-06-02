<#
.SYNOPSIS
Workflow manifest utilities — parse workflow.json, create tasks, merge MCP servers

.DESCRIPTION
Shared functions used by init-project.ps1, workflow-add.ps1, workflow-run.ps1,
and Invoke-DotbotProcess.ps1 for the multi-workflow system.
#>

function Read-WorkflowManifest {
    <#
    .SYNOPSIS
    Parse a workflow.json file into a hashtable.

    .DESCRIPTION
    Parses the workflow manifest schema from JSON.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowDir
    )

    $manifestPath = Join-Path $WorkflowDir "workflow.json"

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
        requires = @{ env_vars = @(); mcp_servers = @(); cli_tools = @() }
        mcp_servers = @{}
        form = @{}
        domain = @{}
        tasks = @()
    }

    if (-not (Test-Path $manifestPath)) {
        return $manifest
    }

    try {
        $raw = Get-Content $manifestPath -Raw
        $parsed = $raw | ConvertFrom-Json -AsHashtable
        if ($parsed) {
            foreach ($key in @($parsed.Keys)) {
                $manifest[$key] = $parsed[$key]
            }
        }
    } catch {
        Write-BotLog -Level Warn -Message "workflow.json parse failed" -Exception $_
    }

    return $manifest
}

function Test-ValidWorkflowDir {
    <#
    .SYNOPSIS
    Returns $true iff $Dir contains a non-empty workflow.json.

    .DESCRIPTION
    Single source of truth for "is this folder a real workflow?" Use before
    calling Read-WorkflowManifest at any site that would otherwise treat the
    defaulted manifest of a missing/empty file as if the folder were valid.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Dir
    )

    $manifestPath = Join-Path $Dir "workflow.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $manifestPath -ErrorAction Stop
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
            $manifestPath,
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
      - Project tier:   <project>/.bot/content/workflows/<name>/
      - Framework tier: <DOTBOT_HOME>/content/workflows/<name>/

    The framework tier resolves through Get-DotbotInstallPath (which
    honours $env:DOTBOT_HOME with the usual ~ expansion). This aligns
    workflow discovery with the rest of the layered content model:
    projects override by adding content under <BotRoot>/content/, and
    the framework no longer ships its source into every .bot/ snapshot.

    Returns a hashtable with absolute paths; the paths are returned
    even if the directories don't yet exist.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    return @{
        project   = (Join-Path $BotRoot 'content' 'workflows')
        framework = (Join-Path (Get-DotbotInstallPath) 'content' 'workflows')
    }
}

function Find-Workflow {
    <#
    .SYNOPSIS
    Resolve a workflow by name through the two-tier registry.

    .DESCRIPTION
    Resolution order:
      1. <BotRoot>/workflows/<Name>/workflow.json         (project tier)
      2. <BotRoot>/content/workflows/<Name>/workflow.json (framework tier)
      3. Not found → returns a WorkflowNotFound error record.

    Returns a hashtable with the following shape on success:
        @{ ok = $true; name = <name>; path = <abs dir>; source = 'project'|'framework' }

    On failure:
        @{ ok = $false; reason = 'WorkflowNotFound'; name = <name>;
           message = '<text>'; tried = @(<paths>) }

    A project workflow with the same name as a framework workflow takes
    precedence — this is how authors customise a built-in without forking.

    `path` is the workflow directory (the parent of workflow.json), so callers
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
    $tried += (Join-Path $projectDir 'workflow.json')
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
    $tried += (Join-Path $frameworkDir 'workflow.json')
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
            icon        = <string>
        }

    Entries are sorted by name. Workflow folders without a valid workflow.json
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

function Test-WorkflowFormFieldSchema {
    <#
    .SYNOPSIS
    Validate form field declarations in a workflow manifest.

    .DESCRIPTION
    Returns an array of error strings, one per malformed field. Checks both
    form.modes[].fields and top-level form.fields. Each field must declare a
    non-empty 'id' and, when 'type' is present, it must be one of: text,
    textarea, toggle.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,

        [string]$WorkflowName = '<unknown>'
    )

    if (-not $WorkflowName -or $WorkflowName -eq '<unknown>') {
        $manifestName = Get-ManifestEntryField -Entry $Manifest -Field 'name'
        if ($manifestName) { $WorkflowName = $manifestName }
    }

    $validTypes = @('text', 'textarea', 'toggle')
    $errors = @()
    $form = Get-ManifestEntryField -Entry $Manifest -Field 'form'

    if (-not $form) {
        return @()
    }

    $fieldOwners = @()
    $modes = Get-ManifestEntryField -Entry $form -Field 'modes'

    if ($modes) {
        $fieldOwners += @($modes)
    } else {
        $fieldOwners += $form
    }

    foreach ($owner in $fieldOwners) {
        $fields = Get-ManifestEntryField -Entry $owner -Field 'fields'

        if (-not $fields) {
            continue
        }

        $i = 0

        foreach ($field in @($fields)) {
            $id = Get-ManifestEntryField -Entry $field -Field 'id'

            if ([string]::IsNullOrWhiteSpace([string]$id)) {
                $rendered = Format-ManifestEntryForError -Entry $field
                $errors += "form fields entry [$i] in workflow '$WorkflowName' is missing the required 'id' field. Entry: $rendered"
            }

            $type = Get-ManifestEntryField -Entry $field -Field 'type'

            if ($type -and ($type -notin $validTypes)) {
                $errors += "form field '$id' in workflow '$WorkflowName' has unknown type '$type'. Expected one of: $($validTypes -join ', ')."
            }

            $i++
        }
    }

    return $errors
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

    $errors += @(Test-WorkflowFormFieldSchema -Manifest $Manifest -WorkflowName $WorkflowName)

    $requires = Get-ManifestEntryField -Entry $Manifest -Field 'requires'
    if (-not $requires) { return $errors }

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

    # Lint: worktree execution is mandatory. Older manifests could opt out with
    # top-level isolated:false or per-task skip_worktree; both are now rejected.
    if ($Manifest -is [System.Collections.IDictionary]) {
        if ($Manifest.Contains('isolated')) {
            $errors += @"
workflow '$WorkflowName' declares the removed field 'isolated'.
Workflow runs always execute in git worktrees. Remove 'isolated' from workflow.json.
"@
        }
    } elseif ($Manifest.PSObject -and $Manifest.PSObject.Properties['isolated']) {
        $errors += @"
workflow '$WorkflowName' declares the removed field 'isolated'.
Workflow runs always execute in git worktrees. Remove 'isolated' from workflow.json.
"@
    }

    $tasks = Get-ManifestEntryField -Entry $Manifest -Field 'tasks'
    if ($tasks) {
        $i = 0
        foreach ($t in @($tasks)) {
            # Hashtable check covers JSON manifests parsed with -AsHashtable;
            # PSCustomObject check covers callers that pass object-shaped data.
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
Workflow runs always execute in git worktrees. Remove 'skip_worktree' from the task.
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
        $WorkflowPath = $null,
        $WorkflowSource = $null
    )

    $startedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Mint a run_id whose derived run directory does not already exist. The
    # directory name is <date>-<slug>-<4char>, where the 4-char short id is
    # derived from the run_id. Two same-day runs of the SAME workflow — now a
    # supported concurrency scenario — can collide on that short id, which would
    # otherwise reuse another run's directory and mix their tasks.
    #
    # Creation is the atomic test-and-claim: New-Item -ItemType Directory
    # WITHOUT -Force fails if the directory already exists, so two runs that mint
    # the same short id cannot both succeed — the loser catches the error and
    # regenerates. No Test-Path/create gap (that would be a TOCTOU race), no
    # timer. The parent (workflow-runs/) is pre-created idempotently first.
    $runsParent = Split-Path -Parent (Get-WorkflowRunLayout -BotRoot $BotRoot -WorkflowName $WorkflowName -RunId (New-WorkflowRunId) -StartedAt $startedAt).run_dir
    New-Item -ItemType Directory -Path $runsParent -Force | Out-Null

    $runId  = $null
    $layout = $null
    for ($attempt = 0; $attempt -lt 16; $attempt++) {
        $candidateId     = New-WorkflowRunId
        $candidateLayout = Get-WorkflowRunLayout -BotRoot $BotRoot -WorkflowName $WorkflowName -RunId $candidateId -StartedAt $startedAt
        try {
            New-Item -ItemType Directory -Path $candidateLayout.run_dir -ErrorAction Stop | Out-Null
            $runId  = $candidateId
            $layout = $candidateLayout
            break
        } catch {
            # Distinguish a genuine short-id collision (dir now exists) from a real
            # failure (permissions, disk full, invalid path). Only the former is
            # curable by regenerating the run_id; re-throw everything else so the
            # actual cause surfaces instead of a misleading "could not mint" error.
            if (Test-Path -LiteralPath $candidateLayout.run_dir) {
                continue
            }
            throw
        }
    }
    if (-not $runId) {
        throw "Initialize-WorkflowRun: could not mint a unique run directory for '$WorkflowName' after 16 attempts."
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $layout.live_status_path) -Force | Out-Null

    $record = New-WorkflowRunRecord `
        -WorkflowName    $WorkflowName `
        -StartedBy       $StartedBy `
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
        bot_root         = $BotRoot
        workflow_path    = $WorkflowPath
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
    'applicable_agents', 'applicable_skills', 'applicable_standards', 'needs_interview',
    'human_hours', 'ai_hours', 'max_concurrent', 'timeout', 'retry',
    'on_failure', 'env', 'post_script'
)

function ConvertTo-DotbotWorkflowContentReferences {
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateSet('agents','skills')]
        [string]$Type,

        $References
    )

    $marker = if ($Type -eq 'agents') { 'AGENT.md' } else { 'SKILL.md' }
    $resolvedReferences = @()
    foreach ($reference in @($References)) {
        if ($null -eq $reference) { continue }
        $raw = ([string]$reference).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $resolved = Resolve-DotbotContentReference -BotRoot $BotRoot -Type $Type -Reference $raw
        if ($resolved) {
            $name = Split-Path -Leaf $resolved
            $resolvedReferences += ".bot/content/$Type/$name/$marker"
        } else {
            $resolvedReferences += $raw
        }
    }

    return @($resolvedReferences)
}

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
        [hashtable]$TaskDef,              # one entry from workflow.json tasks[]

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

    # workflow:<*.md> is the compact prompt-template spelling used by shipped
    # workflows. Store it as a workflow-root prompt path for execution.
    $promptFromWorkflow = $null
    if ($type -in @('prompt','task_gen') -and -not $TaskDef['script_path'] -and -not $TaskDef['script'] `
            -and $TaskDef['workflow'] -and ([string]$TaskDef['workflow'] -match '\.md$')) {
        $type = 'prompt_template'
        $promptFromWorkflow = "prompts/$([string]$TaskDef['workflow'])"
    }
    if ($type -eq 'prompt' -and $TaskDef['prompt']) {
        $type = 'prompt_template'
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
    if ($Run.bot_root) {
        if ($workflowBag.ContainsKey('applicable_agents')) {
            $workflowBag['applicable_agents'] = ConvertTo-DotbotWorkflowContentReferences `
                -BotRoot ([string]$Run.bot_root) -Type agents -References $workflowBag['applicable_agents']
        }
        if ($workflowBag.ContainsKey('applicable_skills')) {
            $workflowBag['applicable_skills'] = ConvertTo-DotbotWorkflowContentReferences `
                -BotRoot ([string]$Run.bot_root) -Type skills -References $workflowBag['applicable_skills']
        }
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

function Get-ActiveWorkflowRuns {
    <#
    .SYNOPSIS
    Return currently running WorkflowRun records for a project.

    .DESCRIPTION
    Joins the live status records under .control/workflow-runs/ with the
    committed run.json records under workspace/tasks/workflow-runs/. The result
    shape is intentionally the same compact shape consumed by Test-CanStartRun.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot
    )

    $controlDir = Join-Path $BotRoot (Join-Path '.control' 'workflow-runs')
    if (-not (Test-Path -LiteralPath $controlDir -PathType Container)) {
        return @()
    }

    $runs = @()
    foreach ($statusFile in @(Get-ChildItem -LiteralPath $controlDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $status = Get-Content -LiteralPath $statusFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            if ($status.status -ne 'running' -or -not $status.run_id) { continue }

            $runDir = Find-WorkflowRunDir -BotRoot $BotRoot -RunId $status.run_id
            if (-not $runDir) { continue }
            $runJson = Join-Path $runDir 'run.json'
            if (-not (Test-Path -LiteralPath $runJson -PathType Leaf)) { continue }

            $record = Get-Content -LiteralPath $runJson -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            $runs += [ordered]@{
                id            = $status.run_id
                status        = $status.status
                workflow_name = $record.workflow_name
            }
        } catch {
            continue
        }
    }

    return ,@($runs)
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
    foreach ($status in @('todo', 'needs-input', 'in-progress', 'needs-review', 'done', 'skipped', 'cancelled', 'split')) {
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
    Pure function. Every workflow run executes in its own git worktree(s) with
    its own run directory (workspace/tasks/workflow-runs/<run>/) and per-run
    launch/product state, so runs are fully isolated from one another.
    Different workflows — and multiple concurrent instances of the SAME
    workflow — can run at once. There is no workflow-level blocking condition;
    the function always permits the start.

    The rule has no side effects and does not touch disk. The runtime HTTP
    server consults this function before transitioning a new WorkflowRun
    to 'running' and turns a Conflict result into an HTTP 409.

    .PARAMETER NewRun
    Hashtable or PSCustomObject describing the run being started.
    Currently unused for the decision (every run is worktree-isolated);
    retained for signature stability and future policy hooks.

    .PARAMETER ActiveRuns
    Array of run records (hashtable / PSCustomObject). Only entries whose
    'status' equals 'running' participate in the decision. Entries should carry
    'id' and 'workflow_name' so the conflict message can point at the blocker.

    .OUTPUTS
    Hashtable with shape:
        @{ ok = $true }   -- always; runs never conflict at the workflow level.

    .EXAMPLE
    Test-CanStartRun -NewRun @{ workflow_name = 'alpha' } -ActiveRuns @(
        @{ id = 'wr_AbCd1234'; workflow_name = 'alpha'; status = 'running' }
    )
    # -> @{ ok = $true }  (a second instance of 'alpha' may run concurrently)
    #>
    param(
        [Parameter(Mandatory)]
        [object]$NewRun,

        [Parameter()]
        [object[]]$ActiveRuns
    )

    if (-not $ActiveRuns) {
        return @{ ok = $true }
    }

    # Every run executes in its own git worktree(s) with a unique run directory
    # and per-run launch/product state, so runs never conflict at the workflow
    # level — including multiple concurrent instances of the same workflow. No
    # blocking condition applies.
    return @{ ok = $true }
}

function Test-GitReadyForWorktree {
    <#
    .SYNOPSIS
    Check whether a project directory satisfies the workflow worktree preconditions.

    .DESCRIPTION
    Starting a WorkflowRun requires that the project directory is a git repo.
    Repositories with no commits are allowed; task worktrees use git's orphan
    worktree mode until the first task commit establishes the base branch.
    Concretely:
        - <ProjectRoot>/.git must exist (directory or gitlink file — gitlink
          covers the worktree case where .git is a small file pointing to the
          real gitdir).
        - If HEAD has commits, 'git rev-list --count HEAD' must return > 0.
        - If HEAD has no commits yet, the repository must still be a valid
          unborn git worktree.

    On success returns @{ ok = $true }. On failure returns @{ ok = $false;
    reason = 'no_git'|'git_unavailable'; message = '<text>' }
    where <text> is the user-facing refusal message:

        "Workflow runs require a git repo. Initialise git first, then retry."

    This is a pure check — it neither modifies anything nor talks to a
    network. Dotbot.Worktree's create call also invokes the check before
    allocating a worktree.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $refusalMessage = @(
        "Workflow runs require a git repo."
        "Initialise git first, then retry."
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
            message = "git CLI is not available on PATH; cannot verify the worktree precondition.`n$refusalMessage"
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

    if ($count -and $count -gt 0) {
        return @{ ok = $true }
    }

    $inside = & git -C $ProjectRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and "$inside".Trim() -eq 'true') {
        return @{ ok = $true }
    }

    if (-not $count -or $count -le 0) {
        return @{
            ok      = $false
            reason  = 'invalid_git_repo'
            message = $refusalMessage
        }
    }
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
    'Test-WorkflowFormFieldSchema'
    'Test-WorkflowManifestSchema'
    'Convert-ManifestRequiresToPreflightChecks'
    'Ensure-ManifestTaskIds'
    'Convert-ManifestTasksToPhases'
    'New-WorkflowTask'
    'Initialize-WorkflowRun'
    'Find-WorkflowRunDir'
    'Get-ActiveWorkflowRuns'
    'Merge-McpServers'
    'Remove-OrphanMcpServers'
    'New-EnvLocalScaffold'
    'Clear-WorkflowTasks'
    'Test-ManifestCondition'
    'Test-CanStartRun'
    'Test-GitReadyForWorktree'

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
