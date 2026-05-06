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
    Workflow to install (e.g., 'start-from-jira'). At most one.

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
    init-project.ps1 -Workflow start-from-jira -Stack dotnet-blazor,dotnet-ef
    Installs default -> start-from-jira (workflow) -> dotnet (auto) -> dotnet-blazor -> dotnet-ef.
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
$CoreDir    = Join-Path $DotbotBase "core"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

# Default to start-from-prompt when no workflow specified.
if (-not $Workflow) {
    $Workflow = 'start-from-prompt'
}

# Import platform functions
Import-Module (Join-Path $DotbotBase "scripts/Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "core/runtime/modules/DotBotTheme.psm1") -Force -DisableNameChecking

# Deprecated workflow aliases
$workflowAliases = @{
    'multi-repo' = 'start-from-jira'
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

# Check if core/ exists
if (-not (Test-Path $CoreDir)) {
    Write-DotbotError "Core directory not found: $CoreDir"
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
    Write-DotbotWarning "Would copy core/ from: $CoreDir"
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

    # PR-5: legacy workflows/default residue at .bot/ root. Pre-PR-5 installs
    # had .bot/workflow.yaml plus old prompts/includes/research at .bot/recipes/.
    # None of these have a consumer in the new layout —
    # remove them so a re-init does not leave a confusing hybrid tree.
    $legacyManifest = Join-Path $Dir "workflow.yaml"
    if (Test-Path $legacyManifest) { Remove-Item -Path $legacyManifest -Force }
    foreach ($legacy in @("recipes/prompts", "recipes/includes", "recipes/research")) {
        $legacyPath = Join-Path $Dir $legacy
        if (Test-Path $legacyPath) { Remove-Item -Path $legacyPath -Recurse -Force }
    }

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
    $systemDirs = @("core", "systems", "recipes", "hooks", "settings")
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
    # Legacy default-workflow content from before PR-5 (when workflows/default
    # was the base layer). Remove so the new layout is not poisoned by stale
    # files. Workspace data and .control/ are preserved above.
    $legacyDefaultPaths = @(
        "recipes/prompts",
        "recipes/includes",
        "recipes/research"
    )
    foreach ($legacy in $legacyDefaultPaths) {
        $legacyPath = Join-Path $BotDir $legacy
        if (Test-Path $legacyPath) {
            Remove-Item -Path $legacyPath -Recurse -Force
        }
    }
}

# Ensure .bot/ exists; create empty if first init.
if (-not (Test-Path $BotDir)) {
    New-Item -ItemType Directory -Path $BotDir -Force | Out-Null
}

# Copy core/ (framework infrastructure) into .bot/core/
Write-Status "Copying core framework files"
$botCoreDir = Join-Path $BotDir "core"
if (Test-Path $botCoreDir) {
    Remove-Item -Path $botCoreDir -Recurse -Force
}
Copy-Item -Path $CoreDir -Destination $botCoreDir -Recurse -Force

# Copy framework scaffolding from core/ into .bot/ root: settings, hooks,
# launcher scripts, README, .gitignore. These are the files PR-5 relocated
# from workflows/default/ into core/ when default was killed off.
$rootFilesToCopy = @("go.ps1", "init.ps1", "README.md", ".gitignore")
foreach ($f in $rootFilesToCopy) {
    $src = Join-Path $CoreDir $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $BotDir $f) -Force
    }
}

foreach ($subdir in @("settings", "hooks", "recipes")) {
    $srcDir = Join-Path $CoreDir $subdir
    $destDir = Join-Path $BotDir $subdir
    if (Test-Path $srcDir) {
        if (Test-Path $destDir) {
            Remove-Item -Path $destDir -Recurse -Force
        }
        Copy-Item -Path $srcDir -Destination $destDir -Recurse -Force
    }
}

# Create empty workspace directories. Forward slashes are accepted by every
# PowerShell file API on every platform, while embedded backslashes are
# treated as literals on Linux/macOS and would corrupt the path tree.
$workspaceDirs = @(
    "workspace/tasks/todo",
    "workspace/tasks/todo/edited_tasks",
    "workspace/tasks/todo/deleted_tasks",
    "workspace/tasks/analysing",
    "workspace/tasks/analysed",
    "workspace/tasks/needs-input",
    "workspace/tasks/in-progress",
    "workspace/tasks/done",
    "workspace/tasks/split",
    "workspace/tasks/skipped",
    "workspace/tasks/cancelled",
    "workspace/sessions",
    "workspace/sessions/runs",
    "workspace/sessions/history",
    "workspace/plans",
    "workspace/product",
    "workspace/decisions/accepted",
    "workspace/decisions/deprecated",
    "workspace/decisions/proposed",
    "workspace/decisions/superseded",
    "workspace/pilot",
    "workspace/reports"
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

# Copy workspace sample templates from core/workspace-template/. Forward
# slashes keep these paths cross-platform.
$workspaceTemplateDir = Join-Path $CoreDir "workspace-template"
if (Test-Path $workspaceTemplateDir) {
    $samplesSrc = Join-Path $workspaceTemplateDir "tasks/samples"
    $samplesDest = Join-Path $BotDir "workspace/tasks/samples"
    if (Test-Path $samplesSrc) {
        if (-not (Test-Path $samplesDest)) {
            New-Item -ItemType Directory -Path $samplesDest -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $samplesSrc "*") -Destination $samplesDest -Recurse -Force
    }
}

Write-Success "Created .bot directory structure"

# ---------------------------------------------------------------------------
# Import workflow manifest utilities
# ---------------------------------------------------------------------------
. (Join-Path $BotDir "core/runtime/modules/workflow-manifest.ps1")

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

            if (-not (Test-ValidWorkflowDir -Dir $wfTargetDir)) {
                Write-DotbotError "Source at '$wfSourceDir' has no usable workflow.yaml. Skipping '$displayName'; not registering as an installed workflow."
                if (Test-Path $wfTargetDir) {
                    Remove-Item -Path $wfTargetDir -Recurse -Force
                }
                continue
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

# Deep-merge utility lives in the shared SettingsLoader module so that runtime
# readers (Get-MothershipConfig, Get-NotificationSettings, InboxWatcher, etc.)
# use the same implementation.
if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $DotbotBase "core/runtime/modules/SettingsLoader.psm1") -DisableNameChecking -Global
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
    Write-Status "Apply order: core -> $($resolvedOrder -join ' -> ')"
}

# --- Install each entry ---
# Stacks overlay onto .bot/ root in full. Workflows ALSO overlay shared
# infrastructure (hooks/verify/, settings/) onto .bot/, but their recipes/,
# tools/, workflow.yaml, and manifest.yaml stay scoped to the per-workflow
# install at .bot/workflows/<name>/ from the earlier loop.
$installedStacks = @()

foreach ($entryName in $resolvedOrder) {
    $entryDir = $catalogDirMap[$entryName]
    $entryDirFull = [System.IO.Path]::GetFullPath($entryDir)
    $meta = $catalogMeta[$entryName]
    $isWorkflow = ($entryName -eq $activeWorkflow)
    $entryType = if ($isWorkflow) { "workflow" } else { "stack" }

    Write-Status "Installing ${entryType}: $entryName"

    Get-ChildItem -Path $entryDir -Recurse -File | ForEach-Object {
        $sourceFileFull = [System.IO.Path]::GetFullPath($_.FullName)
        $relativePath = [System.IO.Path]::GetRelativePath($entryDirFull, $sourceFileFull)
        $relativePathKey = $relativePath -replace '\\', '/'
        $destPath = Join-Path $BotDir $relativePath
        $destDir = Split-Path $destPath -Parent

        # Skip metadata files (not copied to .bot/)
        if ($relativePathKey -eq "on-install.ps1") { return }
        if ($relativePathKey -eq "manifest.yaml") { return }

        # Workflow content stays scoped to .bot/workflows/<name>/ — these
        # paths were already installed by the per-workflow loop and must not
        # leak into .bot/ root.
        if ($isWorkflow) {
            if ($relativePathKey -eq "workflow.yaml") { return }
            if ($relativePathKey -match '^recipes/') { return }
            if ($relativePathKey -match '^systems/mcp/tools/') { return }
            if ($relativePathKey -match '^tools/') { return }
        }

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

    # Merge domain.task_categories from workflow manifest into settings
    if ($isWorkflow) {
        $wfManifestDir = Join-Path $BotDir "workflows/$entryName"
        $wfManifest = $null
        if (Test-Path $wfManifestDir) {
            try {
                . (Join-Path $BotDir "core/runtime/modules/workflow-manifest.ps1")
                $wfManifest = Read-WorkflowManifest -WorkflowDir $wfManifestDir
            } catch { Write-DotbotCommand "Parse skipped: $_" }
        }
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
# Create or merge .mcp.json with MCP server configuration
#
# A pre-existing .mcp.json (e.g. user-maintained `github` / `figma` entries)
# must NOT be overwritten or skipped — we merge core entries in while
# preserving everything the user added. See issue #315.
# ---------------------------------------------------------------------------
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"

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

# Core entries owned by the framework. Order matters — written in this order
# in the resulting file, with any user-added entries appended after.
$coreServers = [ordered]@{
    dotbot = [ordered]@{
        type    = "stdio"
        command = "pwsh"
        args    = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".bot/core/mcp/dotbot-mcp.ps1")
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
}

if (Test-Path $mcpJsonPath) {
    Write-Status "Merging .mcp.json (preserving user entries)"
    try {
        $existing = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw ".mcp.json exists but is not valid JSON: $($_.Exception.Message). Fix or remove the file and re-run dotbot init."
    }

    # Validate root shape. ConvertFrom-Json returns $null for an empty file
    # and unwraps scalars/arrays; both would silently corrupt the merge.
    # Treat $null as "no usable content" and rebuild from a fresh object;
    # throw on any non-object root so the user gets a friendly message.
    if ($null -ne $existing -and -not ($existing -is [System.Management.Automation.PSCustomObject])) {
        throw ".mcp.json root is not a JSON object: got $($existing.GetType().Name). Fix or remove the file and re-run dotbot init."
    }
    if ($null -eq $existing) {
        $existing = [pscustomobject]@{}
    }

    $mergedServers = [ordered]@{}
    $hasMcpServersProp = [bool]$existing.PSObject.Properties['mcpServers']
    if ($hasMcpServersProp -and $existing.mcpServers -and -not ($existing.mcpServers -is [System.Management.Automation.PSCustomObject])) {
        throw ".mcp.json has 'mcpServers' but it is not an object: got $($existing.mcpServers.GetType().Name). Fix or remove the file and re-run dotbot init."
    }
    $existingHasMcpServers = $hasMcpServersProp -and $existing.mcpServers

    # Core entries are framework-owned: always use the canonical value so
    # upgrades after a framework path move (e.g. #345 moved the dotbot MCP
    # server from .bot/systems/ to .bot/core/) self-heal on re-init. User
    # entries with non-core names are preserved verbatim in the next loop.
    foreach ($coreName in $coreServers.Keys) {
        $hadExisting = $existingHasMcpServers -and $existing.mcpServers.PSObject.Properties[$coreName]
        $mergedServers[$coreName] = $coreServers[$coreName]
        $action = if ($hadExisting) { "Refreshed" } else { "Added" }
        Write-DotbotCommand "$action '$coreName' entry"
    }

    # Preserve any non-core (user-added) servers verbatim. Use a
    # case-insensitive name match so a user entry like "Dotbot" is treated
    # as the same key as canonical "dotbot" rather than producing two
    # parallel servers in the merged file.
    if ($existingHasMcpServers) {
        $coreNamesCi = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($coreServers.Keys),
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($prop in $existing.mcpServers.PSObject.Properties) {
            if (-not $coreNamesCi.Contains($prop.Name)) {
                $mergedServers[$prop.Name] = $prop.Value
                Write-DotbotCommand "Preserved '$($prop.Name)' entry"
            }
        }
    }

    # Preserve any non-mcpServers top-level keys (e.g. tool-specific settings)
    # by mutating $existing in place rather than rebuilding from scratch.
    if ($hasMcpServersProp) {
        $existing.mcpServers = $mergedServers
    } else {
        $existing | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue $mergedServers -Force
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content -Path $mcpJsonPath -Encoding UTF8
    Write-Success "Merged .mcp.json"
} else {
    Write-Status "Creating .mcp.json (dotbot + Context7 + Playwright)"
    $mcpConfig = @{ mcpServers = $coreServers }
    $mcpConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $mcpJsonPath -Encoding UTF8
    Write-Success "Created .mcp.json"
}

# ---------------------------------------------------------------------------
# Set up MCP for Codex and Gemini CLIs (if installed)
# ---------------------------------------------------------------------------
$mcpServerScript = ".bot/core/mcp/dotbot-mcp.ps1"

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

# Load framework-owned path list from the canonical source (FrameworkIntegrity.psm1).
# Used for: pre-commit hook case patterns, manifest generation, commit staging.
$frameworkPaths = @()
$frameworkIntegrityModule = Join-Path $ProjectDir ".bot" "core" "mcp" "modules" "FrameworkIntegrity.psm1"
if (-not (Test-Path $frameworkIntegrityModule)) {
    $frameworkIntegrityModule = Join-Path $PSScriptRoot ".." "core" "mcp" "modules" "FrameworkIntegrity.psm1"
}
if (Test-Path $frameworkIntegrityModule) {
    Import-Module $frameworkIntegrityModule -Force
    $frameworkPaths = Get-FrameworkProtectedPaths
}

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

    # Generate shell case patterns from the canonical protected-paths list so the
    # hook stays in sync automatically. Directories get /* for glob matching;
    # individual files stay as-is. .bot/.manifest.json is added unconditionally.
    $shellPatterns = @()
    foreach ($p in $frameworkPaths) {
        $abs = Join-Path $ProjectDir $p
        if ((Test-Path -LiteralPath $abs -PathType Container -ErrorAction SilentlyContinue)) {
            $shellPatterns += "$p/*"
        } else {
            $shellPatterns += $p
        }
    }
    $shellPatterns += '.bot/.manifest.json'
    $shellCase = ($shellPatterns | Sort-Object) -join '|'

    $hookContent = @"
#!/bin/sh
# dotbot: pre-commit hook (gitleaks + privacy scan + reference check + framework-file protection)
# Auto-generated by dotbot init — do not edit manually.
$gitleaksSection
# --- resolve hooks directory (installed .bot/ or source core/) ---
HOOKS_DIR=".bot/core/hooks/verify"
if [ ! -d "`$HOOKS_DIR" ] && [ -d "core/hooks/verify" ]; then
  HOOKS_DIR="core/hooks/verify"
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
# --- dotbot framework file protection ---
# Blocks direct commits to framework-owned files under .bot/. These files
# are managed by ``dotbot init --force``. Set DOTBOT_FORCE_COMMIT=1 to bypass
# (used by the installer itself).
if [ "`$DOTBOT_FORCE_COMMIT" != "1" ]; then
  BLOCKED=""
  OIFS="`$IFS"
  IFS='
'
  for f in `$(git diff --cached --name-only); do
    case "`$f" in
      $shellCase)
        BLOCKED="`$BLOCKED  `$f\n" ;;
    esac
  done
  IFS="`$OIFS"
  if [ -n "`$BLOCKED" ]; then
    echo ""
    echo "ERROR: dotbot framework files cannot be modified directly."
    echo ""
    echo "Blocked files:"
    printf '%b' "`$BLOCKED"
    echo "To update framework files: dotbot init --force"
    echo "To discard changes: git checkout -- <file>"
    exit 1
  fi
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
# Warn if .bot/ is gitignored — the framework requires it to be tracked
# (worktrees use junctions to shared state, and integrity checks rely on
# git-status visibility). See README "Framework file protection".
# ---------------------------------------------------------------------------
$sentinel = Join-Path $ProjectDir ".bot/core/mcp/dotbot-mcp.ps1"
if (Test-Path $sentinel) {
    Push-Location $ProjectDir
    try {
        $null = & git check-ignore -q -- ".bot/core/mcp/dotbot-mcp.ps1" 2>$null
        $botIgnored = ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
    if ($botIgnored) {
        $ignoreSource = & git -C $ProjectDir check-ignore -v -- ".bot/core/mcp/dotbot-mcp.ps1" 2>$null
        Write-DotbotError ".bot/ is gitignored. dotbot requires it to be tracked in git, otherwise framework integrity, worktree state sharing, and the pre-commit guard all silently break."
        if ($ignoreSource) {
            Write-DotbotCommand "Ignore source: $ignoreSource"
        }
        Write-DotbotCommand "Fix: remove the rule (or add '!/.bot/' to re-include), then re-run 'dotbot init --force'."
    }
}

# ---------------------------------------------------------------------------
# Helpers: manifest generation + framework-aware git commit.
#
# The manifest (`.bot/.manifest.json`) holds SHA256 hashes of every framework
# file; it's committed to git so verify hooks and MCP task gates can detect
# tampering (including `git commit --no-verify` bypasses). Generated BEFORE
# each commit so it's included in the same commit.
#
# Submit-ForceCommit wraps the pattern of bypassing the pre-commit
# framework-file guard via DOTBOT_FORCE_COMMIT=1 — used for the initial
# commit and for `init --force` updates.
# ---------------------------------------------------------------------------

function New-FrameworkManifest {
    param(
        [string]$Root,
        [string]$Generator,
        [string[]]$Paths,
        [string[]]$UserPaths = @(
            '.bot/workspace/',
            '.bot/.control/',
            '.bot/profile/'
        )
    )
    $manifestModule = Join-Path $DotbotBase "core" "mcp" "modules" "Manifest.psm1"
    if (-not (Test-Path -LiteralPath $manifestModule)) {
        Write-DotbotWarning "Manifest module not found at $manifestModule — skipping manifest generation"
        return
    }
    if (-not $Paths -or $Paths.Count -eq 0) {
        Write-DotbotWarning "No protected paths provided — skipping manifest generation"
        return
    }
    try {
        Import-Module $manifestModule -Force
        $null = New-DotbotManifest -ProjectRoot $Root -ProtectedPaths $Paths -UserPaths $UserPaths -Generator $Generator
        Write-Success "Framework integrity manifest generated"
    } catch {
        Write-DotbotWarning "Manifest generation failed: $_"
    }
}

function Submit-ForceCommit {
    param(
        [string]$Root,
        [string]$Message
    )
    $previous = $env:DOTBOT_FORCE_COMMIT
    $env:DOTBOT_FORCE_COMMIT = '1'
    try {
        $null = git -C $Root commit --quiet -m $Message 2>$null
        return $LASTEXITCODE
    } finally {
        if ($null -eq $previous) {
            Remove-Item Env:\DOTBOT_FORCE_COMMIT -ErrorAction SilentlyContinue
        } else {
            $env:DOTBOT_FORCE_COMMIT = $previous
        }
    }
}

# ---------------------------------------------------------------------------
# Initial commit (fresh project): manifest + .bot/ + .mcp.json
# First init (existing repo):     manifest + .bot/ + .mcp.json
# --force path:                    manifest + framework paths (only if dirty)
# ---------------------------------------------------------------------------
$hasCommits = git -C $ProjectDir rev-parse HEAD 2>$null
$manifestPath = Join-Path $ProjectDir ".bot" ".manifest.json"
$isFirstInit = -not (Test-Path $manifestPath)

if ($LASTEXITCODE -ne 0) {
    Write-DotbotCommand "Creating initial commit..."
    New-FrameworkManifest -Root $ProjectDir -Generator 'dotbot init' -Paths $frameworkPaths
    git -C $ProjectDir add .bot/ 2>$null
    if (Test-Path (Join-Path $ProjectDir ".mcp.json")) {
        git -C $ProjectDir add .mcp.json 2>$null
    }
    $rc = Submit-ForceCommit -Root $ProjectDir -Message "chore: initialize dotbot"
    if ($rc -eq 0) {
        Write-Success "Initial commit created"
    } else {
        # Unstage everything so leftover staged files don't contaminate future commits
        git -C $ProjectDir reset 2>$null
        Write-DotbotWarning "Initial commit failed -- files unstaged"
    }
} elseif ($Force) {
    # Regenerate the manifest first so it reflects any rewritten framework files;
    # then commit framework paths + manifest if anything actually changed.
    New-FrameworkManifest -Root $ProjectDir -Generator 'dotbot init --force' -Paths $frameworkPaths

    # Keep paths that are on disk OR tracked in git. Drops stale list entries
    # (would abort `git add` with a pathspec error), but preserves
    # tracked-then-deleted paths so migration deletions still get staged.
    $stagePaths = @(($frameworkPaths + @('.bot/.manifest.json')) | Where-Object {
        $abs = Join-Path $ProjectDir $_
        if (Test-Path -LiteralPath $abs) { return $true }
        $tracked = git -C $ProjectDir ls-files -- $_ 2>$null
        return [bool]$tracked
    })
    $dirty = git -C $ProjectDir status --porcelain -- @stagePaths 2>$null
    if ($dirty) {
        Write-DotbotCommand "Committing framework file updates..."
        git -C $ProjectDir add -- @stagePaths 2>$null
        $rc = Submit-ForceCommit -Root $ProjectDir -Message "chore: update dotbot framework files"
        if ($rc -eq 0) {
            Write-Success "Framework update committed"
        } else {
            Write-DotbotWarning "Framework update commit failed — run manually: DOTBOT_FORCE_COMMIT=1 git commit"
        }
    }
} elseif ($isFirstInit) {
    # Existing repo, first dotbot init — same as fresh project but as a new commit.
    Write-DotbotCommand "Committing dotbot files..."
    New-FrameworkManifest -Root $ProjectDir -Generator 'dotbot init' -Paths $frameworkPaths
    git -C $ProjectDir add .bot/ 2>$null
    if (Test-Path (Join-Path $ProjectDir ".mcp.json")) {
        git -C $ProjectDir add .mcp.json 2>$null
    }
    $rc = Submit-ForceCommit -Root $ProjectDir -Message "chore: initialize dotbot"
    if ($rc -eq 0) {
        Write-Success "dotbot commit created"
    } else {
        git -C $ProjectDir reset 2>$null
        Write-DotbotWarning "dotbot commit failed — files unstaged"
    }
}

# ---------------------------------------------------------------------------
# Show completion message
# ---------------------------------------------------------------------------
Write-DotbotBanner -Title "✓ Project Initialized!"
Write-DotbotSection -Title "WHAT'S INSTALLED"
Write-DotbotLabel -Label ".bot/core/mcp/    " -Value "MCP server for task management"
Write-DotbotLabel -Label ".bot/core/ui/     " -Value "Web UI server (default port 8686)"
Write-DotbotLabel -Label ".bot/core/runtime/" -Value "Autonomous loop for Claude CLI"
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


Write-BlankLine
Write-DotbotSection -Title "GET STARTED"
Write-DotbotCommand ".bot\go.ps1"
Write-BlankLine
Write-DotbotSection -Title "NEXT STEPS"
Write-DotbotLabel -Label "1. Start the UI:     " -Value ".bot\go.ps1"
Write-DotbotLabel -Label "2. View docs:        " -Value ".bot\README.md"
Write-BlankLine
