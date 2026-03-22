#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initialize .bot in the current project

.DESCRIPTION
    Copies the default .bot structure to the current project directory.
    Optionally installs profiles for workflow and tech-specific features.
    Checks for required dependencies (git is required; others warn-only).
    Creates .mcp.json with dotbot, Context7, and Playwright MCP servers.
    Installs gitleaks pre-commit hook if gitleaks is available.

    Profiles have two types (declared in profile.yaml):
      - workflow : changes HOW dotbot operates (at most one allowed)
      - stack    : changes WHAT dotbot knows (composable, multiple allowed)
    Stacks may declare 'extends: <parent>' to auto-include a parent stack.

.PARAMETER Profile
    Profile(s) to install (e.g., 'dotnet', 'kickstart-via-jira,dotnet-blazor').
    Accepts a comma-separated string or multiple -Profile values.

.PARAMETER Force
    Overwrite existing .bot system files (preserves workspace data).

.PARAMETER DryRun
    Preview changes without applying.

.EXAMPLE
    init-project.ps1
    Installs base default only.

.EXAMPLE
    init-project.ps1 -Profile dotnet
    Installs base default + dotnet stack.

.EXAMPLE
    init-project.ps1 -Profile kickstart-via-jira,dotnet-blazor,dotnet-ef
    Installs default -> kickstart-via-jira (workflow) -> dotnet (auto) -> dotnet-blazor -> dotnet-ef.
#>

[CmdletBinding()]
param(
    [string[]]$Profile,
    [string[]]$Workflow,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$DefaultDir = Join-Path $DotbotBase "profiles\default"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

# Import platform functions
Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T   v3" -ForegroundColor Blue
Write-Host "    Project Initialization" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

# ---------------------------------------------------------------------------
# Dependency check (git required; others warn-only)
# ---------------------------------------------------------------------------
Write-Host "  DEPENDENCY CHECK" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$depWarnings = 0

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Success "PowerShell 7+ ($($PSVersionTable.PSVersion))"
} else {
    Write-DotbotWarning "PowerShell 7+ is required (current: $($PSVersionTable.PSVersion))"
    Write-Host "    Download from: https://aka.ms/powershell" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Success "Git"
} else {
    Write-DotbotError "Git is required but not installed"
    Write-Host "    Download from: https://git-scm.com/downloads" -ForegroundColor Cyan
    exit 1
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Success "Claude CLI"
} else {
    Write-DotbotWarning "Claude CLI is not installed"
    Write-Host "    Install: npm install -g @anthropic-ai/claude-code" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Success "Codex CLI"
} else {
    Write-DotbotWarning "Codex CLI is not installed"
    Write-Host "    Install: npm install -g @openai/codex" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command gemini -ErrorAction SilentlyContinue) {
    Write-Success "Gemini CLI"
} else {
    Write-DotbotWarning "Gemini CLI is not installed"
    Write-Host "    Install: npm install -g @google/gemini-cli" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Success "Node.js / npx (for Context7 and Playwright MCP)"
} else {
    Write-DotbotWarning "Node.js / npx is not installed (needed for MCP servers)"
    Write-Host "    Download from: https://nodejs.org" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command uvx -ErrorAction SilentlyContinue) {
    Write-Success "uv / uvx (for Serena MCP)"
} else {
    Write-DotbotWarning "uv / uvx is not installed (needed for Serena MCP)"
    Write-Host "    Install: pip install uv  (or see https://docs.astral.sh/uv/)" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    Write-Success "gitleaks"
} else {
    Write-DotbotWarning "gitleaks is not installed (secret scanning)"
    Write-Host "    Install: winget install Gitleaks.Gitleaks" -ForegroundColor Cyan
    $depWarnings++
}

if ($depWarnings -gt 0) {
    Write-Host ""
    Write-DotbotWarning "$depWarnings missing dependency/dependencies -- continuing anyway"
}
Write-Host ""

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
    Write-Host "  Run 'dotbot update' to repair installation" -ForegroundColor Yellow
    exit 1
}

# Check if .bot already exists
if ((Test-Path $BotDir) -and -not $Force) {
    Write-DotbotWarning ".bot directory already exists"
    Write-Host "  Use -Force to overwrite" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Status "Initializing .bot in: $ProjectDir"

if ($DryRun) {
    Write-Host "  Would copy default from: $DefaultDir" -ForegroundColor Yellow
    Write-Host "  Would copy to: $BotDir" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Handle existing .bot with -Force (preserve workspace data)
# ---------------------------------------------------------------------------
$existingInstanceId = $null
if ((Test-Path $BotDir) -and $Force) {
    # Preserve instance_id before replacing defaults/
    $existingSettingsPath = Join-Path $BotDir "defaults\settings.default.json"
    if (Test-Path $existingSettingsPath) {
        try {
            $existingSettings = Get-Content $existingSettingsPath -Raw | ConvertFrom-Json
            if ($existingSettings.PSObject.Properties['instance_id'] -and $existingSettings.instance_id) {
                $parsedGuid = [guid]::Empty
                if ([guid]::TryParse("$($existingSettings.instance_id)", [ref]$parsedGuid)) {
                    $existingInstanceId = $parsedGuid.ToString()
                }
            }
        } catch {}
    }

    Write-Status "Updating .bot system files (preserving workspace data)"
    # Remove only system/config directories and root files -- never workspace/ or .control/
    $systemDirs = @("systems", "prompts", "hooks", "defaults")
    foreach ($dir in $systemDirs) {
        $dirPath = Join-Path $BotDir $dir
        if (Test-Path $dirPath) {
            Remove-Item -Path $dirPath -Recurse -Force
        }
    }
    $rootFiles = @("go.ps1", "init.ps1", "README.md", ".gitignore")
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
if ($Workflow -and $Workflow.Count -gt 0) {
    Write-Host ""
    Write-Host "  WORKFLOW INSTALL" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

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
                # Check built-in profiles dir
                $candidate = Join-Path (Join-Path $DotbotBase "profiles") $wfName
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

                # Skip profile metadata files
                if ($relativePathKey -eq "profile-init.ps1") { return }
                if ($relativePathKey -eq "profile.yaml") { return }

                # Remap legacy paths: systems/mcp/tools/* -> tools/*
                if ($relativePathKey -match '^systems/mcp/tools/(.+)$') {
                    $relativePath = "tools/$($Matches[1])"
                }
                # Remap: defaults/settings.default.json -> settings.json
                if ($relativePathKey -eq "defaults/settings.default.json") {
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
                # Auto-generate from profile.yaml
                $profileYaml = Join-Path $wfSourceDir "profile.yaml"
                if (Test-Path $profileYaml) {
                    Copy-Item $profileYaml $wfYamlTarget -Force
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
                    Write-Host "    Merged $addedCount MCP server(s) into .mcp.json" -ForegroundColor Gray
                }
            }

            # Run profile-init.ps1 if present in source
            $wfInitScript = Join-Path $wfSourceDir "profile-init.ps1"
            if (Test-Path $wfInitScript) {
                Write-Status "Running $displayName init script"
                & $wfInitScript
            }

            $installedWorkflows += $displayName
            Write-Success "Installed workflow: $displayName"
        }
    }

    # Record installed workflows in core settings
    $settingsPath = Join-Path $BotDir "defaults\settings.default.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $settings | Add-Member -NotePropertyName "installed_workflows" -NotePropertyValue $installedWorkflows -Force
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    }
}

# ---------------------------------------------------------------------------
# Profile taxonomy: resolve, validate, and install profiles (stacks)
# ---------------------------------------------------------------------------
$ProfilesDir = Join-Path $DotbotBase "profiles"

# Backward-compat aliases (deprecated names -> canonical profile names)
$profileAliases = @{
    "multi-repo" = "kickstart-via-jira"
}

# Normalise -Profile input: accept comma-separated strings and/or arrays
$requestedProfiles = @()
$aliasWarningsShown = @{}
if ($Profile -and $Profile.Count -gt 0) {
    foreach ($entry in $Profile) {
        foreach ($token in ($entry -split ',')) {
            $trimmed = $token.Trim()
            if ($trimmed) {
                $aliasKey = $trimmed.ToLowerInvariant()
                if ($profileAliases.ContainsKey($aliasKey)) {
                    $canonical = $profileAliases[$aliasKey]
                    if (-not $aliasWarningsShown.ContainsKey($aliasKey)) {
                        Write-DotbotWarning "Profile '$trimmed' is deprecated and will be removed in a future release. Use '$canonical' instead."
                        $aliasWarningsShown[$aliasKey] = $true
                    }
                    $requestedProfiles += $canonical
                } else {
                    $requestedProfiles += $trimmed
                }
            }
        }
    }

    # Deduplicate while preserving the first-seen order (case-insensitive)
    $dedupedProfiles = @()
    $seenRequestedProfiles = @{}
    foreach ($name in $requestedProfiles) {
        $key = $name.ToLowerInvariant()
        if (-not $seenRequestedProfiles.ContainsKey($key)) {
            $seenRequestedProfiles[$key] = $true
            $dedupedProfiles += $name
        }
    }
    $requestedProfiles = $dedupedProfiles
}

# --- Helper: parse a simple profile.yaml (no external YAML module needed) ---
function Read-ProfileYaml {
    param([string]$ProfileDir)
    $yamlPath = Join-Path $ProfileDir "profile.yaml"
    $meta = @{ type = "stack"; name = (Split-Path $ProfileDir -Leaf); description = ""; extends = $null }
    if (Test-Path $yamlPath) {
        Get-Content $yamlPath | ForEach-Object {
            if ($_ -match '^\s*(type|name|description|extends)\s*:\s*(.+)$') {
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

# --- Helper: resolve profile directory (built-in or registry namespace) ---
function Resolve-ProfileDir {
    param([string]$Name)
    # Check for namespace prefix (e.g., "myorg:my-workflow")
    if ($Name -match '^([^:]+):(.+)$') {
        $namespace = $Matches[1]
        $profileName = $Matches[2]
        $RegistriesDir = Join-Path $DotbotBase "registries"
        # Search in workflows/ then stacks/ under the registry
        foreach ($contentType in @("workflows", "stacks")) {
            $candidate = Join-Path $RegistriesDir "$namespace\$contentType\$profileName"
            if (Test-Path $candidate) {
                return $candidate
            }
        }
        return $null
    }
    # Built-in profile
    $candidate = Join-Path $ProfilesDir $Name
    if (Test-Path $candidate) { return $candidate }
    return $null
}

# --- Resolve extends chains and validate taxonomy ---
$resolvedOrder = @()            # final ordered list of profile names to install
$workflowProfile = $null        # at most one
$stackProfiles = @()            # zero or more
$profileMeta = @{}              # name -> metadata hash
$profileDirMap = @{}            # name -> resolved directory path

if ($requestedProfiles.Count -gt 0) {
    Write-Host ""
    Write-Host "  PROFILE RESOLUTION" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    # First pass: read metadata for all requested profiles and resolve extends
    $toProcess = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $requestedProfiles) { $toProcess.Enqueue($name) }
    $seen = @{}

    while ($toProcess.Count -gt 0) {
        $name = $toProcess.Dequeue()
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true

        $profileDir = Resolve-ProfileDir $name
        if (-not $profileDir) {
            Write-DotbotError "Profile not found: $name"
            Write-Host "    Available profiles:" -ForegroundColor Yellow
            Get-ChildItem -Path $ProfilesDir -Directory | Where-Object { $_.Name -ne "default" } | ForEach-Object { Write-Host "      - $($_.Name)" }
            # Also list registry profiles if any registries exist
            $RegistriesDir = Join-Path $DotbotBase "registries"
            if (Test-Path $RegistriesDir) {
                Get-ChildItem -Path $RegistriesDir -Directory | ForEach-Object {
                    $ns = $_.Name
                    foreach ($ct in @("workflows", "stacks")) {
                        $ctDir = Join-Path $_.FullName $ct
                        if (Test-Path $ctDir) {
                            Get-ChildItem -Path $ctDir -Directory | ForEach-Object {
                                Write-Host "      - ${ns}:$($_.Name)" -ForegroundColor Cyan
                            }
                        }
                    }
                }
            }
            exit 1
        }
        $profileDirMap[$name] = $profileDir
        if ($name -match ':') {
            Write-Host "    Registry: $name -> $profileDir" -ForegroundColor Magenta
        }

        $meta = Read-ProfileYaml $profileDir
        $profileMeta[$name] = $meta

        # If this profile extends another, queue the parent
        if ($meta.extends -and -not $seen.ContainsKey($meta.extends)) {
            $toProcess.Enqueue($meta.extends)
            Write-Host "    Auto-including '$($meta.extends)' (required by '$name')" -ForegroundColor Gray
        }
    }

    # Separate workflows from stacks
    foreach ($name in $profileMeta.Keys) {
        $meta = $profileMeta[$name]
        if ($meta.type -eq "workflow") {
            # Legacy --Profile workflow support (backward compat)
            # Prefer --Workflow for new projects
            $workflowProfile = $name
            Write-Host "    Workflow: $name (legacy --Profile path)" -ForegroundColor Cyan
        } else {
            $stackProfiles += $name
            $label = $name
            if ($meta.extends) { $label += " (extends: $($meta.extends))" }
            Write-Host "    Stack:    $label" -ForegroundColor Cyan
        }
    }

    # Build final order: workflow first, then stacks in dependency-resolved order
    if ($workflowProfile) { $resolvedOrder += $workflowProfile }

    # Topological sort for stacks (parents before children)
    $stackSorted = @()
    $visited = @{}
    function Visit-Stack ($name) {
        if ($visited.ContainsKey($name)) { return }
        $visited[$name] = $true
        $parent = $profileMeta[$name].extends
        if ($parent -and $profileMeta.ContainsKey($parent)) {
            Visit-Stack $parent
        }
        $script:stackSorted += $name
    }
    foreach ($name in $stackProfiles) { Visit-Stack $name }
    $resolvedOrder += $stackSorted

    Write-Host ""
    Write-Status "Apply order: default -> $($resolvedOrder -join ' -> ')"
}

# --- Install each profile (overlay on top of default) ---
$installedStacks = @()

foreach ($profileName in $resolvedOrder) {
    $profileDir = if ($profileDirMap.ContainsKey($profileName)) { $profileDirMap[$profileName] } else { Join-Path $ProfilesDir $profileName }
    $profileDirFull = [System.IO.Path]::GetFullPath($profileDir)
    $meta = $profileMeta[$profileName]

    Write-Status "Installing profile: $profileName ($($meta.type))"

    # Copy profile files (overlay on top of default)
    Get-ChildItem -Path $profileDir -Recurse -File | ForEach-Object {
        $sourceFileFull = [System.IO.Path]::GetFullPath($_.FullName)
        $relativePath = [System.IO.Path]::GetRelativePath($profileDirFull, $sourceFileFull)
        $relativePathKey = $relativePath -replace '\\', '/'
        $destPath = Join-Path $BotDir $relativePath
        $destDir = Split-Path $destPath -Parent

        # Skip profile metadata files (not copied to .bot/)
        if ($relativePathKey -eq "profile-init.ps1") { return }
        if ($relativePathKey -eq "profile.yaml") { return }

        # Handle config.json merging for hooks/verify
        if ($relativePathKey -eq "hooks/verify/config.json") {
            $baseConfigPath = [System.IO.Path]::Combine($BotDir, "hooks", "verify", "config.json")
            if (Test-Path $baseConfigPath) {
                $baseConfig = Get-Content $baseConfigPath -Raw | ConvertFrom-Json
                $profileConfig = Get-Content $_.FullName -Raw | ConvertFrom-Json

                $existingNames = @{}
                foreach ($s in @($baseConfig.scripts)) { $existingNames[$s.name] = $true }
                $mergedScripts = @($baseConfig.scripts)
                foreach ($s in @($profileConfig.scripts)) {
                    if (-not $existingNames.ContainsKey($s.name)) {
                        $mergedScripts += $s
                    }
                }
                $baseConfig.scripts = $mergedScripts

                $baseConfig | ConvertTo-Json -Depth 10 | Set-Content $baseConfigPath
                Write-Host "    Merged: $relativePath" -ForegroundColor Gray
                return
            }
        }

        # Handle settings.default.json deep-merge
        if ($relativePathKey -eq "defaults/settings.default.json") {
            $baseSettingsPath = [System.IO.Path]::Combine($BotDir, "defaults", "settings.default.json")
            if (Test-Path $baseSettingsPath) {
                $baseSettings = Get-Content $baseSettingsPath -Raw | ConvertFrom-Json
                $profileSettings = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $merged = Merge-DeepSettings $baseSettings $profileSettings
                $merged | ConvertTo-Json -Depth 10 | Set-Content $baseSettingsPath
                Write-Host "    Merged: $relativePath" -ForegroundColor Gray
                return
            }
        }

        # Create directory if needed
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # Copy file
        Copy-Item -Path $_.FullName -Destination $destPath -Force
        Write-Host "    Copied: $relativePath" -ForegroundColor Gray
    }

    # Clean stale default workflows when a workflow profile is installed
    if ($meta.type -eq "workflow") {
        $workflowDir = Join-Path $BotDir "prompts\workflows"
        if (Test-Path $workflowDir) {
            # Collect filenames the overlay just provided
            $overlayWorkflowDir = Join-Path $profileDir "prompts\workflows"
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
                Write-Host "    Removed stale default workflow: $($_.Name)" -ForegroundColor DarkYellow
            }
        }
    }

    if ($meta.type -eq "stack") { $installedStacks += $profileName }
    Write-Success "Installed profile: $profileName ($($meta.type))"

    # Run profile init script if present
    $profileInitScript = Join-Path $profileDir "profile-init.ps1"
    if (Test-Path $profileInitScript) {
        Write-Status "Running $profileName init script"
        & $profileInitScript
    }
}

# --- Record installed profiles in settings ---
if ($resolvedOrder.Count -gt 0) {
    $settingsPath = Join-Path $BotDir "defaults\settings.default.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($workflowProfile) {
            $settings | Add-Member -NotePropertyName "profile" -NotePropertyValue $workflowProfile -Force
        }
        if ($installedStacks.Count -gt 0) {
            $settings | Add-Member -NotePropertyName "stacks" -NotePropertyValue $installedStacks -Force
        }
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    }
}

# Ensure workspace instance GUID exists (preserve on -Force re-init)
$workspaceSettingsPath = Join-Path $BotDir "defaults\settings.default.json"
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
    Write-Host "  - Codex CLI not found, skipping MCP registration" -ForegroundColor DarkGray
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
    Write-Host "  - Gemini CLI not found, skipping MCP registration" -ForegroundColor DarkGray
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
    Write-Host "  ✓ .gitignore already covers dotbot defaults" -ForegroundColor DarkGray
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
# dotbot: pre-commit hook (gitleaks + privacy scan)
# Auto-generated by dotbot init — do not edit manually.
$gitleaksSection
# --- dotbot privacy scan ---
"$pwshCmd" -NoProfile -ExecutionPolicy Bypass -Command '
  `$r = & ".bot/hooks/verify/00-privacy-scan.ps1" -StagedOnly | ConvertFrom-Json;
  if (-not `$r.success) { exit 1 }'
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
    Write-Host "  Creating initial commit..." -ForegroundColor DarkGray
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
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  ✓ Project Initialized!" -ForegroundColor Green
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  WHAT'S INSTALLED" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    .bot/systems/mcp/    " -NoNewline -ForegroundColor Yellow
Write-Host "MCP server for task management" -ForegroundColor White
Write-Host "    .bot/systems/ui/     " -NoNewline -ForegroundColor Yellow
Write-Host "Web UI server (default port 8686)" -ForegroundColor White
Write-Host "    .bot/systems/runtime/" -NoNewline -ForegroundColor Yellow
Write-Host "Autonomous loop for Claude CLI" -ForegroundColor White
Write-Host "    .bot/prompts/        " -NoNewline -ForegroundColor Yellow
Write-Host "Agents, skills, workflows" -ForegroundColor White
if ($installedWorkflows.Count -gt 0 -or $resolvedOrder.Count -gt 0) {
    Write-Host ""
    Write-Host "  PROFILES INSTALLED" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    if ($installedWorkflows.Count -gt 0) {
        foreach ($wf in $installedWorkflows) {
            Write-Host "    workflow: $wf" -ForegroundColor Cyan
        }
    }
    if ($workflowProfile) {
        Write-Host "    workflow: $workflowProfile (legacy)" -ForegroundColor Cyan
    }
    if ($installedStacks.Count -gt 0) {
        Write-Host "    stacks:   $($installedStacks -join ', ')" -ForegroundColor Cyan
    }
}

# ---------------------------------------------------------------------------
# Show profile-specific dependency checks (from kickstart.preflight)
# ---------------------------------------------------------------------------
$settingsDefaultPath = Join-Path $BotDir "defaults\settings.default.json"
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
        Write-Host ""
        Write-Host "  PROFILE DEPENDENCIES" -ForegroundColor Blue
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""

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
                        } catch {}
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
                    Write-Host "    $hint" -ForegroundColor DarkGray
                }
                $depWarningCount++
            }
        }

        if ($depWarningCount -gt 0) {
            Write-Host ""
            Write-Host "  .env.local is a project-level file (in the same folder as .bot/) for" -ForegroundColor DarkGray
            Write-Host "  secrets and credentials. It is gitignored. Create it and add the missing" -ForegroundColor DarkGray
            Write-Host "  variables as KEY=value pairs, one per line." -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "  GET STARTED" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    .bot\go.ps1" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT STEPS" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    1. Start the UI:     " -NoNewline -ForegroundColor Yellow
Write-Host ".bot\go.ps1" -ForegroundColor White
Write-Host "    2. View docs:        " -NoNewline -ForegroundColor Yellow
Write-Host ".bot\README.md" -ForegroundColor White
Write-Host ""
