#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initialize .bot in the current project

.DESCRIPTION
    Copies the default .bot structure to the current project directory.
    Optionally installs a workflow and/or tech-specific stacks.
    Checks for required dependencies (git is required; others warn-only).
    Creates .mcp.json with dotbot, Context7, and Playwright MCP servers.
    Installs gitleaks pre-commit hook if gitleaks is available.

    Workflows change HOW dotbot operates (at most one).
    Stacks change WHAT dotbot knows (composable, multiple allowed).
    Stacks may declare 'extends: <parent>' to auto-include a parent stack.

.PARAMETER Workflow
    Workflow to install (e.g., 'kickstart-via-jira'). At most one.

.PARAMETER Stack
    Stack(s) to install (e.g., 'dotnet', 'dotnet-blazor,dotnet-ef').
    Accepts a comma-separated string or multiple -Stack values.

.PARAMETER Force
    Overwrite existing .bot system files (preserves workspace data).

.PARAMETER DryRun
    Preview changes without applying.

.EXAMPLE
    init-project.ps1
    Installs base default only.

.EXAMPLE
    init-project.ps1 -Stack dotnet
    Installs base default + dotnet stack.

.EXAMPLE
    init-project.ps1 -Workflow kickstart-via-jira -Stack dotnet-blazor,dotnet-ef
    Installs default -> kickstart-via-jira (workflow) -> dotnet (auto) -> dotnet-blazor -> dotnet-ef.
#>

[CmdletBinding()]
param(
    [string]$Workflow,
    [string[]]$Stack,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Reset strict mode — callers (e.g. setup-iwg-scoring) may set
# Set-StrictMode -Version Latest which propagates here and breaks
# intrinsic .Count on non-collection types like [string].
Set-StrictMode -Off

$DotbotBase = Join-Path $HOME "dotbot"
$DefaultDir = Join-Path $DotbotBase "workflows\default"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

# Import platform functions
Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force

# Deprecated workflow aliases
$workflowAliases = @{
    'multi-repo' = 'kickstart-via-jira'
}
if ($Workflow -and $workflowAliases.ContainsKey($Workflow)) {
    $resolved = $workflowAliases[$Workflow]
    Write-BlankLine
    Write-DotbotWarning "'$Workflow' is deprecated — use '$resolved' instead"
    $Workflow = $resolved
}

Write-DotbotBanner -Title "D O T B O T   v3.5" -Subtitle "Project Initialization"

# ---------------------------------------------------------------------------
# Dependency check (git required; others warn-only)
# ---------------------------------------------------------------------------
Write-DotbotSection -Title "DEPENDENCY CHECK"

$depWarnings = 0

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Success "PowerShell 7+ ($($PSVersionTable.PSVersion))"
} else {
    Write-DotbotWarning "PowerShell 7+ is required (current: $($PSVersionTable.PSVersion))"
    Write-DotbotCommand "Download from: https://aka.ms/powershell"
    $depWarnings++
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Success "Git"
} else {
    Write-DotbotError "Git is required but not installed"
    Write-DotbotCommand "Download from: https://git-scm.com/downloads"
    exit 1
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Success "Claude CLI"
} else {
    Write-DotbotWarning "Claude CLI is not installed"
    Write-DotbotCommand "Install: npm install -g @anthropic-ai/claude-code"
    $depWarnings++
}

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Success "Codex CLI"
} else {
    Write-DotbotWarning "Codex CLI is not installed"
    Write-DotbotCommand "Install: npm install -g @openai/codex"
    $depWarnings++
}

if (Get-Command gemini -ErrorAction SilentlyContinue) {
    Write-Success "Gemini CLI"
} else {
    Write-DotbotWarning "Gemini CLI is not installed"
    Write-DotbotCommand "Install: npm install -g @google/gemini-cli"
    $depWarnings++
}

if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Success "Node.js / npx (for Context7 and Playwright MCP)"
} else {
    Write-DotbotWarning "Node.js / npx is not installed (needed for MCP servers)"
    Write-DotbotCommand "Download from: https://nodejs.org"
    $depWarnings++
}

if (Get-Command uvx -ErrorAction SilentlyContinue) {
    Write-Success "uv / uvx (for Serena MCP)"
} else {
    Write-DotbotWarning "uv / uvx is not installed (needed for Serena MCP)"
    Write-DotbotCommand "Install: pip install uv  (or see https://docs.astral.sh/uv/)"
    $depWarnings++
}

if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    Write-Success "gitleaks"
} else {
    Write-DotbotWarning "gitleaks is not installed (secret scanning)"
    Write-DotbotCommand "Install: winget install Gitleaks.Gitleaks"
    $depWarnings++
}

if ($depWarnings -gt 0) {
    Write-BlankLine
    Write-DotbotWarning "$depWarnings missing dependency/dependencies -- continuing anyway"
}
Write-BlankLine

# Ensure project is a git repository
$gitDir = Join-Path $ProjectDir ".git"
if (-not (Test-Path $gitDir)) {
    Write-Status "No .git directory found -- initializing git repository"
    & git init $ProjectDir
    Write-Success "Initialized git repository"
}

# Check if default exists
if (-not (Test-Path $DefaultDir)) {
    Write-DotbotError "Default directory not found: $DefaultDir"
    Write-DotbotWarning "Run 'dotbot update' to repair installation"
    exit 1
}

# Check if .bot already exists
if ((Test-Path $BotDir) -and -not $Force) {
    Write-DotbotWarning ".bot directory already exists"
    Write-DotbotWarning "Use -Force to overwrite"
    Write-BlankLine
    exit 1
}

Write-Status "Initializing .bot in: $ProjectDir"

if ($DryRun) {
    Write-DotbotWarning "Would copy default from: $DefaultDir"
    Write-DotbotWarning "Would copy to: $BotDir"
    Write-BlankLine
    exit 0
}

# ---------------------------------------------------------------------------
# Migrate legacy folder names (defaults→settings, prompts→recipes, adrs→decisions)
# ---------------------------------------------------------------------------
function Invoke-BotFolderMigration {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return }

    # defaults/ → settings/
    $old = Join-Path $Dir "defaults"
    $new = Join-Path $Dir "settings"
    if ((Test-Path $old) -and -not (Test-Path $new)) { Rename-Item $old $new }

    # prompts/workflows/ → prompts/_prompts_tmp, then prompts/ → recipes/, then rename inner
    $oldInner = Join-Path $Dir "prompts\workflows"
    $newInner = Join-Path $Dir "prompts\_prompts_tmp"
    if ((Test-Path $oldInner) -and -not (Test-Path $newInner)) { Rename-Item $oldInner $newInner }
    $oldOuter = Join-Path $Dir "prompts"
    $newOuter = Join-Path $Dir "recipes"
    if ((Test-Path $oldOuter) -and -not (Test-Path $newOuter)) {
        Rename-Item $oldOuter $newOuter
        $tmpInner = Join-Path $newOuter "_prompts_tmp"
        $finalInner = Join-Path $newOuter "prompts"
        if ((Test-Path $tmpInner) -and -not (Test-Path $finalInner)) { Rename-Item $tmpInner $finalInner }
    }

    # workspace/adrs/ → workspace/decisions/
    $oldAdrs = Join-Path $Dir "workspace\adrs"
    $newDec = Join-Path $Dir "workspace\decisions"
    if ((Test-Path $oldAdrs) -and -not (Test-Path $newDec)) { Rename-Item $oldAdrs $newDec }

    # Migrate installed workflow subdirectories
    $wfDir = Join-Path $Dir "workflows"
    if (Test-Path $wfDir) {
        Get-ChildItem $wfDir -Directory | ForEach-Object {
            Invoke-BotFolderMigration -Dir $_.FullName
        }
    }
}

# Run migration on existing .bot if present
if (Test-Path $BotDir) {
    Invoke-BotFolderMigration -Dir $BotDir
}

# ---------------------------------------------------------------------------
# Handle existing .bot with -Force (preserve workspace data)
# ---------------------------------------------------------------------------
$existingInstanceId = $null
if ((Test-Path $BotDir) -and $Force) {
    # Preserve instance_id before replacing settings/
    $existingSettingsPath = Join-Path $BotDir "settings\settings.default.json"
    if (Test-Path $existingSettingsPath) {
        try {
            $existingSettings = Get-Content $existingSettingsPath -Raw | ConvertFrom-Json
            if ($existingSettings.PSObject.Properties['instance_id'] -and $existingSettings.instance_id) {
                $parsedGuid = [guid]::Empty
                if ([guid]::TryParse("$($existingSettings.instance_id)", [ref]$parsedGuid)) {
                    $existingInstanceId = $parsedGuid.ToString()
                }
            }
        } catch { Write-DotbotCommand "Parse skipped: $_" }
    }

    Write-Status "Updating .bot system files (preserving workspace data)"
    # Remove only system/config directories and root files -- never workspace/ or .control/
    $systemDirs = @("systems", "recipes", "hooks", "settings")
    foreach ($dir in $systemDirs) {
        $dirPath = Join-Path $BotDir $dir
        if (Test-Path $dirPath) {
            Remove-Item -Path $dirPath -Recurse -Force
        }
    }
    $rootFiles = @("go.ps1", "init.ps1", "README.md", ".gitignore", "workflow.yaml")
    foreach ($file in $rootFiles) {
        $filePath = Join-Path $BotDir $file
        if (Test-Path $filePath) {
            Remove-Item -Path $filePath -Force
        }
    }
}

# Copy default to .bot
Write-Status "Copying default files"
if (Test-Path $BotDir) {
    # .bot exists (Force path) -- copy contents on top, preserving workspace
    Copy-Item -Path (Join-Path $DefaultDir "*") -Destination $BotDir -Recurse -Force
} else {
    Copy-Item -Path $DefaultDir -Destination $BotDir -Recurse -Force
}

# Create empty workspace directories
$workspaceDirs = @(
    "workspace\tasks\todo",
    "workspace\tasks\todo\edited_tasks",
    "workspace\tasks\todo\deleted_tasks",
    "workspace\tasks\analysing",
    "workspace\tasks\analysed",
    "workspace\tasks\needs-input",
    "workspace\tasks\in-progress",
    "workspace\tasks\done",
    "workspace\tasks\split",
    "workspace\tasks\skipped",
    "workspace\tasks\cancelled",
    "workspace\sessions",
    "workspace\sessions\runs",
    "workspace\sessions\history",
    "workspace\plans",
    "workspace\product",
    "workspace\feedback\pending",
    "workspace\feedback\applied",
    "workspace\feedback\archived"
)

foreach ($dir in $workspaceDirs) {
    $fullPath = Join-Path $BotDir $dir
    if (-not (Test-Path $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }
    # Add .gitkeep to empty directories
    $gitkeep = Join-Path $fullPath ".gitkeep"
    if (-not (Test-Path $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep -Force | Out-Null
    }
}

Write-Success "Created .bot directory structure"

# ---------------------------------------------------------------------------
# Import workflow manifest utilities
# ---------------------------------------------------------------------------
. (Join-Path $BotDir "systems\runtime\modules\workflow-manifest.ps1")

# ---------------------------------------------------------------------------
# Workflow install (new multi-workflow system)
# ---------------------------------------------------------------------------
$installedWorkflows = @()
if ($Workflow) {
    Write-BlankLine
    Write-DotbotSection -Title "WORKFLOW INSTALL"

    # Ensure workflows directory exists
    $workflowsBaseDir = Join-Path $BotDir "workflows"
    if (-not (Test-Path $workflowsBaseDir)) {
        New-Item -Path $workflowsBaseDir -ItemType Directory -Force | Out-Null
    }

    $RegistriesDir = Join-Path $DotbotBase "registries"

    foreach ($wfSpec in $Workflow) {
        foreach ($wfToken in ($wfSpec -split ',')) {
            $wfName = $wfToken.Trim()
            if (-not $wfName) { continue }

            # Resolve workflow source directory (registry or built-in)
            $wfSourceDir = $null
            if ($wfName -match '^([^:]+):(.+)$') {
                $namespace = $Matches[1]
                $wfShortName = $Matches[2]
                $candidate = Join-Path $RegistriesDir "$namespace\workflows\$wfShortName"
                if (Test-Path $candidate) { $wfSourceDir = $candidate }
                $displayName = $wfShortName
            } else {
            # Check built-in workflows dir
                $candidate = Join-Path (Join-Path $DotbotBase "workflows") $wfName
                if (Test-Path $candidate) { $wfSourceDir = $candidate }
                $displayName = $wfName
            }

            if (-not $wfSourceDir) {
                Write-DotbotError "Workflow not found: $wfName"
                continue
            }

            Write-Status "Installing workflow: $displayName"

            # Target directory: .bot/workflows/{name}/
            $wfTargetDir = Join-Path $workflowsBaseDir $displayName
            if ((Test-Path $wfTargetDir) -and $Force) {
                Remove-Item $wfTargetDir -Recurse -Force
            }
            if (-not (Test-Path $wfTargetDir)) {
                New-Item -Path $wfTargetDir -ItemType Directory -Force | Out-Null
            }

            # Copy all workflow files (skip profile metadata)
            $wfSourceDirFull = [System.IO.Path]::GetFullPath($wfSourceDir)
            Get-ChildItem -Path $wfSourceDir -Recurse -File | ForEach-Object {
                $sourceFileFull = [System.IO.Path]::GetFullPath($_.FullName)
                $relativePath = [System.IO.Path]::GetRelativePath($wfSourceDirFull, $sourceFileFull)
                $relativePathKey = $relativePath -replace '\\', '/'

            # Skip metadata files
            if ($relativePathKey -eq "on-install.ps1") { return }
            if ($relativePathKey -eq "manifest.yaml") { return }

                # Remap legacy paths: systems/mcp/tools/* -> tools/*
                if ($relativePathKey -match '^systems/mcp/tools/(.+)$') {
                    $relativePath = "tools/$($Matches[1])"
                }
                # Remap: settings/settings.default.json -> settings.json
                if ($relativePathKey -eq "settings/settings.default.json") {
                    $relativePath = "settings.json"
                }

                $destPath = Join-Path $wfTargetDir $relativePath
                $destDir = Split-Path $destPath -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -Path $_.FullName -Destination $destPath -Force
            }

            # Copy workflow.yaml if it exists (preferred), otherwise generate minimal one
            $wfYamlSource = Join-Path $wfSourceDir "workflow.yaml"
            $wfYamlTarget = Join-Path $wfTargetDir "workflow.yaml"
            if (Test-Path $wfYamlSource) {
                Copy-Item $wfYamlSource $wfYamlTarget -Force
            } elseif (-not (Test-Path $wfYamlTarget)) {
                # Auto-generate from manifest.yaml
                $manifestYaml = Join-Path $wfSourceDir "manifest.yaml"
                if (Test-Path $manifestYaml) {
                    Copy-Item $manifestYaml $wfYamlTarget -Force
                }
            }

            # Parse manifest for env vars and MCP servers
            $manifest = Read-WorkflowManifest -WorkflowDir $wfTargetDir

            # Scaffold .env.local from requires.env_vars
            $envVars = @()
            if ($manifest.requires -and $manifest.requires.env_vars) {
                $envVars = @($manifest.requires.env_vars)
            } elseif ($manifest.requires -and $manifest.requires['env_vars']) {
                $envVars = @($manifest.requires['env_vars'])
            }
            if ($envVars.Count -gt 0) {
                $envLocalPath = Join-Path $ProjectDir ".env.local"
                New-EnvLocalScaffold -EnvLocalPath $envLocalPath -EnvVars $envVars
                # Ensure .env.local is gitignored
                $gi = Join-Path $ProjectDir ".gitignore"
                if (Test-Path $gi) {
                    $giContent = Get-Content $gi -Raw
                    if ($giContent -notmatch '\.env\.local') {
                        Add-Content $gi ".env.local"
                    }
                }
            }

            # Merge MCP servers into .mcp.json
            if ($manifest.mcp_servers -and ($manifest.mcp_servers.Count -gt 0 -or ($manifest.mcp_servers.PSObject -and $manifest.mcp_servers.PSObject.Properties.Count -gt 0))) {
                $mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
                $addedCount = Merge-McpServers -McpJsonPath $mcpJsonPath -WorkflowServers $manifest.mcp_servers
                if ($addedCount -gt 0) {
                    Write-DotbotCommand "Merged $addedCount MCP server(s) into .mcp.json"
                }
            }

            # Run init script if present in source
            $wfInitScript = Join-Path $wfSourceDir "on-install.ps1"
            if (Test-Path $wfInitScript) {
                Write-Status "Running $displayName init script"
                & $wfInitScript
            }

            $installedWorkflows += $displayName
            Write-Success "Installed workflow: $displayName"
        }
    }

    # Record installed workflows in core settings
    $settingsPath = Join-Path $BotDir "settings\settings.default.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $settings | Add-Member -NotePropertyName "installed_workflows" -NotePropertyValue $installedWorkflows -Force
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    }
}

# ---------------------------------------------------------------------------
# Resolve workflow + stacks and install overlays
# ---------------------------------------------------------------------------
$WorkflowsDir = Join-Path $DotbotBase "workflows"
$StacksDir = Join-Path $DotbotBase "stacks"

# Normalise -Stack input: accept comma-separated strings and/or arrays
$requestedStacks = @()
if ($Stack -and $Stack.Count -gt 0) {
    foreach ($entry in $Stack) {
        foreach ($token in ($entry -split ',')) {
            $trimmed = $token.Trim()
            if ($trimmed) { $requestedStacks += $trimmed }
        }
    }

    # Deduplicate while preserving the first-seen order (case-insensitive)
    $dedupedStacks = @()
    $seenStacks = @{}
    foreach ($name in $requestedStacks) {
        $key = $name.ToLowerInvariant()
        if (-not $seenStacks.ContainsKey($key)) {
            $seenStacks[$key] = $true
            $dedupedStacks += $name
        }
    }
    $requestedStacks = $dedupedStacks
}

# --- Helper: parse a manifest.yaml (no external YAML module needed) ---
function Read-ManifestYaml {
    param([string]$Dir)
    $yamlPath = Join-Path $Dir "manifest.yaml"
    $meta = @{ name = (Split-Path $Dir -Leaf); description = ""; extends = $null }
    if (Test-Path $yamlPath) {
        Get-Content $yamlPath | ForEach-Object {
            if ($_ -match '^\s*(name|description|extends)\s*:\s*(.+)$') {
                $meta[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    return $meta
}

# --- Helper: deep-merge two PSCustomObjects / hashtables ---
function Merge-DeepSettings {
    param($Base, $Override)
    if ($null -eq $Base) { return $Override }
    if ($null -eq $Override) { return $Base }

    # Convert PSCustomObject to ordered hashtable for mutation
    function ConvertTo-OrderedHash ($obj) {
        if ($obj -is [System.Collections.IDictionary]) { return $obj }
        $h = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }

    $result = ConvertTo-OrderedHash $Base
    $over = ConvertTo-OrderedHash $Override

    foreach ($key in $over.Keys) {
        $overVal = $over[$key]
        if ($result.Contains($key)) {
            $baseVal = $result[$key]
            if ($baseVal -is [System.Collections.IDictionary] -or ($baseVal -is [PSCustomObject] -and $baseVal.PSObject.Properties.Count -gt 0)) {
                # Recurse into nested objects
                $result[$key] = Merge-DeepSettings $baseVal $overVal
            } elseif ($baseVal -is [System.Collections.IList] -and $overVal -is [System.Collections.IList]) {
                # Arrays of objects (e.g. kickstart phases): replace entirely (ordered pipelines)
                # Arrays of scalars (e.g. task_categories): concat + dedup
                $hasObjects = ($overVal | Where-Object { $_ -is [PSCustomObject] } | Select-Object -First 1)
                if ($hasObjects) {
                    # Ordered pipeline — override replaces base entirely
                    $result[$key] = $overVal
                } else {
                    # Scalar array — concat + dedup
                    $merged = [System.Collections.ArrayList]::new(@($baseVal))
                    foreach ($item in $overVal) {
                        if ($merged -notcontains $item) { $merged.Add($item) | Out-Null }
                    }
                    $result[$key] = @($merged)
                }
            } else {
                # Scalars: last writer wins
                $result[$key] = $overVal
            }
        } else {
            $result[$key] = $overVal
        }
    }
    return $result
}

# --- Helper: resolve stack directory (built-in or registry namespace) ---
function Resolve-StackDir {
    param([string]$Name)
    # Check for namespace prefix (e.g., "myorg:my-stack")
    if ($Name -match '^([^:]+):(.+)$') {
        $namespace = $Matches[1]
        $stackName = $Matches[2]
        $RegistriesDir = Join-Path $DotbotBase "registries"
        $candidate = Join-Path $RegistriesDir "$namespace\stacks\$stackName"
        if (Test-Path $candidate) { return $candidate }
        return $null
    }
    # Built-in stack
    $candidate = Join-Path $StacksDir $Name
    if (Test-Path $candidate) { return $candidate }
    return $null
}

# --- Resolve workflow + extends chains for stacks ---
$resolvedOrder = @()            # final ordered list of names to install
$activeWorkflow = $null         # resolved workflow name (at most one)
$stackNames = @()               # zero or more
$catalogMeta = @{}              # name -> metadata hash
$catalogDirMap = @{}            # name -> resolved directory path

# Resolve workflow (from --Workflow param, at most one)
if ($Workflow) {
    $wfDir = $null
    if ($Workflow -match '^([^:]+):(.+)$') {
        $ns = $Matches[1]; $wfShort = $Matches[2]
        $candidate = Join-Path (Join-Path $DotbotBase "registries") "$ns\workflows\$wfShort"
        if (Test-Path $candidate) { $wfDir = $candidate }
    } else {
        $candidate = Join-Path $WorkflowsDir $Workflow
        if (Test-Path $candidate) { $wfDir = $candidate }
    }
    if (-not $wfDir) {
        Write-DotbotError "Workflow not found: $Workflow"
        Write-DotbotWarning "Available workflows:"
        if (Test-Path $WorkflowsDir) {
            Get-ChildItem -Path $WorkflowsDir -Directory | ForEach-Object { Write-Status "- $($_.Name)" }
        }
        exit 1
    }
    $activeWorkflow = $Workflow
    $catalogDirMap[$Workflow] = $wfDir
    $catalogMeta[$Workflow] = Read-ManifestYaml $wfDir
}

if ($requestedStacks.Count -gt 0 -or $activeWorkflow) {
    Write-BlankLine
    Write-DotbotSection -Title "RESOLUTION"

    if ($activeWorkflow) {
        Write-DotbotLabel -Label "Workflow  " -Value "$activeWorkflow"
    }

    # Resolve stacks + extends chains
    $toProcess = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $requestedStacks) { $toProcess.Enqueue($name) }
    $seen = @{}

    while ($toProcess.Count -gt 0) {
        $name = $toProcess.Dequeue()
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true

        $stackDir = Resolve-StackDir $name
        if (-not $stackDir) {
            Write-DotbotError "Stack not found: $name"
            Write-DotbotWarning "Available stacks:"
            if (Test-Path $StacksDir) {
                Get-ChildItem -Path $StacksDir -Directory | ForEach-Object { Write-Status "- $($_.Name)" }
            }
            $RegistriesDir = Join-Path $DotbotBase "registries"
            if (Test-Path $RegistriesDir) {
                Get-ChildItem -Path $RegistriesDir -Directory | ForEach-Object {
                    $ns = $_.Name
                    $ctDir = Join-Path $_.FullName "stacks"
                    if (Test-Path $ctDir) {
                        Get-ChildItem -Path $ctDir -Directory | ForEach-Object {
                            Write-Status "- ${ns}:$($_.Name)"
                        }
                    }
                }
            }
            exit 1
        }
        $catalogDirMap[$name] = $stackDir
        if ($name -match ':') {
            Write-Status "Registry: $name -> $stackDir"
        }

        $meta = Read-ManifestYaml $stackDir
        $catalogMeta[$name] = $meta
        $stackNames += $name

        # If this stack extends another, queue the parent
        if ($meta.extends -and -not $seen.ContainsKey($meta.extends)) {
            $toProcess.Enqueue($meta.extends)
            Write-DotbotCommand "Auto-including '$($meta.extends)' (required by '$name')"
        }

        $label = $name
        if ($meta.extends) { $label += " (extends: $($meta.extends))" }
        Write-DotbotLabel -Label "Stack     " -Value "$label"
    }

    # Build final order: workflow first, then stacks in dependency-resolved order
    if ($activeWorkflow) { $resolvedOrder += $activeWorkflow }

    # Topological sort for stacks (parents before children)
    $stackSorted = @()
    $visited = @{}
    function Visit-Stack ($name) {
        if ($visited.ContainsKey($name)) { return }
        $visited[$name] = $true
        $parent = $catalogMeta[$name].extends
        if ($parent -and $catalogMeta.ContainsKey($parent)) {
            Visit-Stack $parent
        }
        $script:stackSorted += $name
    }
    foreach ($name in $stackNames) { Visit-Stack $name }
    $resolvedOrder += $stackSorted

    Write-BlankLine
    Write-Status "Apply order: default -> $($resolvedOrder -join ' -> ')"
}

# --- Install each entry (overlay on top of default) ---
$installedStacks = @()

foreach ($entryName in $resolvedOrder) {
    $entryDir = $catalogDirMap[$entryName]
    $entryDirFull = [System.IO.Path]::GetFullPath($entryDir)
    $meta = $catalogMeta[$entryName]
    $isWorkflow = ($entryName -eq $activeWorkflow)
    $entryType = if ($isWorkflow) { "workflow" } else { "stack" }

    Write-Status "Installing ${entryType}: $entryName"

    # Copy files (overlay on top of default)
    Get-ChildItem -Path $entryDir -Recurse -File | ForEach-Object {
        $sourceFileFull = [System.IO.Path]::GetFullPath($_.FullName)
        $relativePath = [System.IO.Path]::GetRelativePath($entryDirFull, $sourceFileFull)
        $relativePathKey = $relativePath -replace '\\', '/'
        $destPath = Join-Path $BotDir $relativePath
        $destDir = Split-Path $destPath -Parent

        # Skip metadata files (not copied to .bot/)
        if ($relativePathKey -eq "on-install.ps1") { return }
        if ($relativePathKey -eq "manifest.yaml") { return }
        if ($relativePathKey -eq "workflow.yaml") { return }  # Preserve default manifest; installed workflows live in workflows/<name>/

        # Skip workflow-scoped prompts (already installed to .bot/workflows/<name>/)
        if ($isWorkflow -and $relativePathKey -match '^recipes/(agents|skills|includes)/') { return }

        # Handle config.json merging for hooks/verify
        if ($relativePathKey -eq "hooks/verify/config.json") {
            $baseConfigPath = [System.IO.Path]::Combine($BotDir, "hooks", "verify", "config.json")
            if (Test-Path $baseConfigPath) {
                $baseConfig = Get-Content $baseConfigPath -Raw | ConvertFrom-Json
                $overlayConfig = Get-Content $_.FullName -Raw | ConvertFrom-Json

                $existingNames = @{}
                foreach ($s in @($baseConfig.scripts)) { $existingNames[$s.name] = $true }
                $mergedScripts = @($baseConfig.scripts)
                foreach ($s in @($overlayConfig.scripts)) {
                    if (-not $existingNames.ContainsKey($s.name)) {
                        $mergedScripts += $s
                    }
                }
                $baseConfig.scripts = $mergedScripts

                $baseConfig | ConvertTo-Json -Depth 10 | Set-Content $baseConfigPath
                Write-DotbotCommand "Merged: $relativePath"
                return
            }
        }

        # Handle settings.default.json deep-merge
        if ($relativePathKey -eq "settings/settings.default.json") {
            $baseSettingsPath = [System.IO.Path]::Combine($BotDir, "settings", "settings.default.json")
            if (Test-Path $baseSettingsPath) {
                $baseSettings = Get-Content $baseSettingsPath -Raw | ConvertFrom-Json
                $overlaySettings = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $merged = Merge-DeepSettings $baseSettings $overlaySettings
                $merged | ConvertTo-Json -Depth 10 | Set-Content $baseSettingsPath
                Write-DotbotCommand "Merged: $relativePath"
                return
            }
        }

        # Create directory if needed
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # Copy file
        Copy-Item -Path $_.FullName -Destination $destPath -Force
        Write-DotbotCommand "Copied: $relativePath"
    }

    # Clean stale default workflows when a workflow is installed
    if ($isWorkflow) {
        $workflowDir = Join-Path $BotDir "recipes\prompts"
        if (Test-Path $workflowDir) {
            # Collect filenames the overlay just provided
            $overlayWorkflowDir = Join-Path $entryDir "recipes\prompts"
            $overlayFiles = @{}
            if (Test-Path $overlayWorkflowDir) {
                Get-ChildItem -Path $overlayWorkflowDir -File | ForEach-Object {
                    $overlayFiles[$_.Name] = $true
                }
            }
            # Remove 00-89 range .md files NOT provided by the overlay
            Get-ChildItem -Path $workflowDir -File -Filter "*.md" | Where-Object {
                $_.Name -match '^[0-8]\d' -and -not $overlayFiles.ContainsKey($_.Name)
            } | ForEach-Object {
                Remove-Item -Path $_.FullName -Force
                Write-DotbotWarning "Removed stale default workflow: $($_.Name)"
            }
        }
    }

    # Merge domain.task_categories from workflow manifest into settings
    if ($isWorkflow) {
        $wfManifestDir = Join-Path $BotDir "workflows\$entryName"
        if (-not (Test-Path $wfManifestDir)) { $wfManifestDir = Join-Path $BotDir "" }
        $wfManifest = $null
        try {
            . "$BotDir\systems\runtime\modules\workflow-manifest.ps1"
            $wfManifest = Read-WorkflowManifest -WorkflowDir $wfManifestDir
        } catch { Write-DotbotCommand "Parse skipped: $_" }
        if ($wfManifest -and $wfManifest.domain -and $wfManifest.domain['task_categories']) {
            $wfCategories = @($wfManifest.domain['task_categories'])
            $settingsFile = Join-Path $BotDir "settings\settings.default.json"
            if (Test-Path $settingsFile) {
                $sObj = Get-Content $settingsFile -Raw | ConvertFrom-Json
                $currentCategories = @()
                if ($sObj.PSObject.Properties['task_categories']) { $currentCategories = @($sObj.task_categories) }
                $mergedCategories = @($currentCategories + $wfCategories | Select-Object -Unique)
                $sObj | Add-Member -NotePropertyName "task_categories" -NotePropertyValue $mergedCategories -Force
                $sObj | ConvertTo-Json -Depth 10 | Set-Content $settingsFile
            }
        }
    }

    if (-not $isWorkflow) { $installedStacks += $entryName }
    Write-Success "Installed ${entryType}: $entryName"

    # Run init script if present
    $initScript = Join-Path $entryDir "on-install.ps1"
    if (Test-Path $initScript) {
        Write-Status "Running $entryName init script"
        & $initScript
    }
}

# --- Record workflow + stacks in settings ---
if ($resolvedOrder.Count -gt 0) {
    $settingsPath = Join-Path $BotDir "settings\settings.default.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($activeWorkflow) {
            $settings | Add-Member -NotePropertyName "workflow" -NotePropertyValue $activeWorkflow -Force
        }
        if ($installedStacks.Count -gt 0) {
            $settings | Add-Member -NotePropertyName "stacks" -NotePropertyValue $installedStacks -Force
        }
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    }
}

# Ensure workspace instance GUID exists (preserve on -Force re-init)
$workspaceSettingsPath = Join-Path $BotDir "settings\settings.default.json"
if (Test-Path $workspaceSettingsPath) {
    try {
        $settings = Get-Content $workspaceSettingsPath -Raw | ConvertFrom-Json
        $currentInstanceId = if ($settings.PSObject.Properties['instance_id']) { "$($settings.instance_id)" } else { "" }
        $parsedCurrentGuid = [guid]::Empty

        if ([guid]::TryParse($currentInstanceId, [ref]$parsedCurrentGuid)) {
            $finalInstanceId = $parsedCurrentGuid.ToString()
        } elseif ($existingInstanceId) {
            $finalInstanceId = $existingInstanceId
        } else {
            $finalInstanceId = [guid]::NewGuid().ToString()
        }

        $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue $finalInstanceId -Force
        $settings | ConvertTo-Json -Depth 10 | Set-Content $workspaceSettingsPath
        Write-Success "Workspace instance: $($finalInstanceId.Substring(0,8))"
    } catch {
        Write-DotbotWarning "Failed to set workspace instance ID: $($_.Exception.Message)"
    }
}
# Run .bot/init.ps1 to set up .claude integration
$initScript = Join-Path $BotDir "init.ps1"
if (Test-Path $initScript) {
    Write-Status "Setting up Claude Code integration"
    & $initScript
}

# ---------------------------------------------------------------------------
# Create .mcp.json with MCP server configuration
# ---------------------------------------------------------------------------
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
if (Test-Path $mcpJsonPath) {
    Write-DotbotWarning ".mcp.json already exists -- skipping"
} else {
    Write-Status "Creating .mcp.json (dotbot + Context7 + Playwright + Serena)"

    # Playwright MCP output goes to .bot/.control/ (gitignored) — uses a relative
    # path so .mcp.json doesn't contain absolute user paths that trip the privacy scan
    $pwOutputDir = ".bot/.control/playwright-output"

    # On Windows, npx must be invoked via 'cmd /c' for stdio MCP servers
    if ($IsWindows) {
        $npxCommand = "cmd"
        $npxContext7Args = @("/c", "npx", "-y", "@upstash/context7-mcp@latest")
        $npxPlaywrightArgs = @("/c", "npx", "-y", "@playwright/mcp@latest", "--output-dir", $pwOutputDir)
    } else {
        $npxCommand = "npx"
        $npxContext7Args = @("-y", "@upstash/context7-mcp@latest")
        $npxPlaywrightArgs = @("-y", "@playwright/mcp@latest", "--output-dir", $pwOutputDir)
    }

    $mcpConfig = @{
        mcpServers = [ordered]@{
            dotbot = [ordered]@{
                type    = "stdio"
                command = "pwsh"
                args    = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".bot\systems\mcp\dotbot-mcp.ps1")
                env     = @{}
            }
            context7 = [ordered]@{
                type    = "stdio"
                command = $npxCommand
                args    = $npxContext7Args
                env     = @{}
            }
            playwright = [ordered]@{
                type    = "stdio"
                command = $npxCommand
                args    = $npxPlaywrightArgs
                env     = @{}
            }
            serena = [ordered]@{
                type    = "stdio"
                command = "uvx"
                args    = @("--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server")
                env     = @{}
            }
        }
    }
    $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $mcpJsonPath -Encoding UTF8
    Write-Success "Created .mcp.json"
}

# ---------------------------------------------------------------------------
# Set up MCP for Codex and Gemini CLIs (if installed)
# ---------------------------------------------------------------------------
$mcpServerScript = ".bot\systems\mcp\dotbot-mcp.ps1"

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Status "Registering dotbot MCP server with Codex CLI..."
    try {
        Push-Location $ProjectDir
        codex mcp add dotbot -- pwsh -NoProfile -ExecutionPolicy Bypass -File $mcpServerScript 2>$null
        Write-Success "Codex MCP server registered"
    } catch {
        Write-DotbotWarning "Failed to register Codex MCP server: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
} else {
    Write-DotbotCommand "- Codex CLI not found, skipping MCP registration"
}

if (Get-Command gemini -ErrorAction SilentlyContinue) {
    Write-Status "Registering dotbot MCP server with Gemini CLI..."
    try {
        Push-Location $ProjectDir
        gemini mcp add dotbot -- pwsh -NoProfile -ExecutionPolicy Bypass -File $mcpServerScript 2>$null
        Write-Success "Gemini MCP server registered"
    } catch {
        Write-DotbotWarning "Failed to register Gemini MCP server: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
} else {
    Write-DotbotCommand "- Gemini CLI not found, skipping MCP registration"
}

# ---------------------------------------------------------------------------
# Ensure common patterns are gitignored in the project root
# ---------------------------------------------------------------------------
$projectGitignore = Join-Path $ProjectDir ".gitignore"
$requiredIgnores = @(
    ".serena/"
    ".codex/"
    ".gemini/"
    "node_modules/"
    "test-results/"
    "playwright-report/"
    ".vscode/mcp.json"
    ".idea"
    ".DS_Store"
    ".env"
    "sessions/"
)

$existingContent = ""
if (Test-Path $projectGitignore) {
    $existingContent = Get-Content $projectGitignore -Raw
}

$entriesToAdd = @()
foreach ($pattern in $requiredIgnores) {
    $escaped = [regex]::Escape($pattern.TrimEnd('/'))
    if ($existingContent -notmatch "(?m)^\s*$escaped/?(\s|$)") {
        $entriesToAdd += $pattern
    }
}

if ($entriesToAdd.Count -gt 0) {
    $block = "`n# dotbot defaults (auto-added by dotbot init)`n"
    foreach ($pattern in $entriesToAdd) {
        $block += "$pattern`n"
    }
    Add-Content -Path $projectGitignore -Value $block -Encoding UTF8
    Write-Success "Added $($entriesToAdd.Count) entries to .gitignore"
} else {
    Write-DotbotCommand "✓ .gitignore already covers dotbot defaults"
}

# ---------------------------------------------------------------------------
# Install pre-commit hook (gitleaks + dotbot privacy scan)
# ---------------------------------------------------------------------------
$hooksDir = Join-Path $gitDir "hooks"
$preCommitPath = Join-Path $hooksDir "pre-commit"

# Determine if an existing hook is ours (dotbot-managed) or user-created
$existingHookIsOurs = $false
if (Test-Path $preCommitPath) {
    $existingContent = Get-Content $preCommitPath -Raw -ErrorAction SilentlyContinue
    if ($existingContent -and $existingContent -match '# dotbot:') {
        $existingHookIsOurs = $true
    }
}

if ((Test-Path $preCommitPath) -and -not $existingHookIsOurs) {
    Write-DotbotWarning "pre-commit hook already exists (not dotbot-managed) -- skipping"
} else {
    Write-Status "Installing pre-commit hook"
    if (-not (Test-Path $hooksDir)) {
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    }

    # --- Gitleaks section (conditional on availability) ---
    $gitleaksSection = ""
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        # On Windows, Git Bash cannot execute WinGet app execution aliases (reparse
        # points).  Resolve the real binary path so the hook calls it directly.
        $gitleaksCmd = "gitleaks"
        if ($IsWindows) {
            $resolved = Get-Command gitleaks -ErrorAction SilentlyContinue
            if ($resolved) {
                $target = (Get-Item $resolved.Source -ErrorAction SilentlyContinue).Target
                if ($target) {
                    $gitleaksCmd = $target -replace '\\', '/'
                } else {
                    $gitleaksCmd = ($resolved.Source) -replace '\\', '/'
                }
            }
        }
        $gitleaksSection = @"

# --- gitleaks ---
"$gitleaksCmd" git --pre-commit --staged || exit `$?
"@
    }

    # --- Resolve pwsh path for Git Bash on Windows ---
    $pwshCmd = "pwsh"
    if ($IsWindows) {
        $resolvedPwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($resolvedPwsh) {
            $target = (Get-Item $resolvedPwsh.Source -ErrorAction SilentlyContinue).Target
            if ($target) {
                $pwshCmd = $target -replace '\\', '/'
            } else {
                $pwshCmd = ($resolvedPwsh.Source) -replace '\\', '/'
            }
        }
    }

    $hookContent = @"
#!/bin/sh
# dotbot: pre-commit hook (gitleaks + privacy scan + reference check)
# Auto-generated by dotbot init — do not edit manually.
$gitleaksSection
# --- resolve hooks directory (installed .bot/ or source workflows/default/) ---
HOOKS_DIR=".bot/hooks/verify"
if [ ! -d "`$HOOKS_DIR" ] && [ -d "workflows/default/hooks/verify" ]; then
  HOOKS_DIR="workflows/default/hooks/verify"
fi
export HOOKS_DIR
# --- dotbot privacy scan ---
if [ -f "`$HOOKS_DIR/00-privacy-scan.ps1" ]; then
  "$pwshCmd" -NoProfile -ExecutionPolicy Bypass -Command '
    `$r = & "`$env:HOOKS_DIR/00-privacy-scan.ps1" -StagedOnly | ConvertFrom-Json;
    if (-not `$r.success) { exit 1 }'
fi
# --- dotbot reference check ---
if [ -f "`$HOOKS_DIR/03-check-md-refs.ps1" ]; then
  "$pwshCmd" -NoProfile -ExecutionPolicy Bypass -Command '
    `$script = "`$env:HOOKS_DIR/03-check-md-refs.ps1";
    if (Test-Path `$script) {
      `$r = & `$script -StagedOnly | ConvertFrom-Json;
      if (-not `$r.success) { exit 1 }
    }'
fi
"@
    Set-Content -Path $preCommitPath -Value $hookContent -Encoding UTF8 -NoNewline
    # Make executable on non-Windows platforms
    if (-not $IsWindows) {
        & chmod +x $preCommitPath 2>$null
    }
    Write-Success "Installed pre-commit hook"
}

# ---------------------------------------------------------------------------
# Create initial commit so worktrees can branch from it later
# ---------------------------------------------------------------------------
$hasCommits = git -C $ProjectDir rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-DotbotCommand "Creating initial commit..."
    git -C $ProjectDir add .bot/ 2>$null
    if (Test-Path (Join-Path $ProjectDir ".mcp.json")) {
        git -C $ProjectDir add .mcp.json 2>$null
    }
    git -C $ProjectDir commit --quiet -m "chore: initialize dotbot" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Initial commit created"
    } else {
        # Unstage everything so leftover staged files don't contaminate future commits
        git -C $ProjectDir reset 2>$null
        Write-DotbotWarning "Initial commit failed -- files unstaged"
    }
}

# ---------------------------------------------------------------------------
# Show completion message
# ---------------------------------------------------------------------------
Write-DotbotBanner -Title "✓ Project Initialized!"
Write-DotbotSection -Title "WHAT'S INSTALLED"
Write-DotbotLabel -Label ".bot/systems/mcp/    " -Value "MCP server for task management"
Write-DotbotLabel -Label ".bot/systems/ui/     " -Value "Web UI server (default port 8686)"
Write-DotbotLabel -Label ".bot/systems/runtime/" -Value "Autonomous loop for Claude CLI"
Write-DotbotLabel -Label ".bot/recipes/        " -Value "Agents, skills, prompts"
if ($installedWorkflows.Count -gt 0 -or $resolvedOrder.Count -gt 0) {
    Write-BlankLine
    Write-DotbotSection -Title "INSTALLED"
    if ($installedWorkflows.Count -gt 0) {
        foreach ($wf in $installedWorkflows) {
            Write-DotbotLabel -Label "workflow  " -Value "$wf"
        }
    }
    if ($activeWorkflow) {
        Write-DotbotLabel -Label "workflow  " -Value "$activeWorkflow"
    }
    if ($installedStacks.Count -gt 0) {
        Write-DotbotLabel -Label "stacks    " -Value "$($installedStacks -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Show workflow-specific dependency checks (from kickstart.preflight)
# ---------------------------------------------------------------------------
$settingsDefaultPath = Join-Path $BotDir "settings\settings.default.json"
if (Test-Path $settingsDefaultPath) {
    try {
        $finalSettings = Get-Content $settingsDefaultPath -Raw | ConvertFrom-Json
        $preflightChecks = @()
        if ($finalSettings.kickstart -and $finalSettings.kickstart.preflight) {
            $preflightChecks = @($finalSettings.kickstart.preflight)
        }
    } catch {
        $preflightChecks = @()
    }

    if ($preflightChecks.Count -gt 0) {
        Write-BlankLine
    Write-DotbotSection -Title "WORKFLOW DEPENDENCIES"

        $mcpListCache = $null
        $envLocalPath = Join-Path $ProjectDir ".env.local"
        $depWarningCount = 0

        foreach ($check in $preflightChecks) {
            $label = if ($check.message) { $check.message } else { $check.name }
            $hint  = $check.hint
            $passed = $false

            switch ($check.type) {
                'env_var' {
                    $varName = if ($check.var) { $check.var } else { $check.name }
                    $envValue = $null
                    if (Test-Path $envLocalPath) {
                        $envLines = Get-Content $envLocalPath -ErrorAction SilentlyContinue
                        foreach ($line in $envLines) {
                            if ($line -match "^\s*$([regex]::Escape($varName))\s*=\s*(.+)$") {
                                $envValue = $matches[1].Trim()
                            }
                        }
                    }
                    $passed = [bool]$envValue
                    if (-not $hint -and -not $passed) {
                        $hint = "Set $varName in .env.local"
                    }
                }
                'mcp_server' {
                    $mcpFound = $false
                    if (Test-Path $mcpJsonPath) {
                        try {
                            $mcpData = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json
                            if ($mcpData.mcpServers -and $mcpData.mcpServers.PSObject.Properties.Name -contains $check.name) {
                                $mcpFound = $true
                            }
                        } catch { Write-DotbotCommand "Parse skipped: $_" }
                    }
                    if (-not $mcpFound) {
                        if ($null -eq $mcpListCache) {
                            try { $mcpListCache = & claude mcp list 2>&1 | Out-String }
                            catch { $mcpListCache = "" }
                        }
                        if ($mcpListCache -match "(?m)^$([regex]::Escape($check.name)):") {
                            $mcpFound = $true
                        }
                    }
                    $passed = $mcpFound
                    if (-not $hint -and -not $passed) {
                        $hint = "Register '$($check.name)' server in .mcp.json or via 'claude mcp add'"
                    }
                }
                'cli_tool' {
                    $passed = $null -ne (Get-Command $check.name -ErrorAction SilentlyContinue)
                    if (-not $hint -and -not $passed) {
                        $hint = "Install '$($check.name)' and ensure it is on PATH"
                    }
                }
            }

            if ($passed) {
                Write-Success $label
            } else {
                Write-DotbotWarning $label
                if ($hint) {
                    Write-DotbotCommand "$hint"
                }
                $depWarningCount++
            }
        }

        if ($depWarningCount -gt 0) {
            Write-BlankLine
            Write-DotbotCommand ".env.local is a project-level file (in the same folder as .bot/) for"
            Write-DotbotCommand "secrets and credentials. It is gitignored. Create it and add the missing"
            Write-DotbotCommand "variables as KEY=value pairs, one per line."
        }
    }
}

Write-BlankLine
Write-DotbotSection -Title "GET STARTED"
Write-DotbotCommand ".bot\go.ps1"
Write-BlankLine
Write-DotbotSection -Title "NEXT STEPS"
Write-DotbotLabel -Label "1. Start the UI:     " -Value ".bot\go.ps1"
Write-DotbotLabel -Label "2. View docs:        " -Value ".bot\README.md"
Write-BlankLine
