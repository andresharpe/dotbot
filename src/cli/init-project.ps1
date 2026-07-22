#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initialize .bot/ in the current project.

.DESCRIPTION
    Creates only project-specific .bot/ artefacts:
      - .bot/workspace/   tracked workspace tree seeded from
                          <DOTBOT_HOME>/content/workspace-template/
      - .bot/.gitignore   gitignores runtime state under .bot/

    Optional project-tier directories are created only when a requested
    workflow/stack ships overrides. Each resulting directory contains the
    source manifest and base files with the override files applied, so it is
    a valid runtime content item. Registry items are materialised because
    their source is outside the built-in content tier.

    Active workflow and stacks are recorded in .bot/.control/settings.json
    when those flags are passed. By default, framework content (src/,
    content/, hooks/) is not copied — the runtime resolves it from
    $env:DOTBOT_HOME via the layered content resolver.

    Pass --copy-runtime to also copy the dotbot runtime into
    .bot/runtime so commands run inside the project prefer that copy
    over DOTBOT_HOME.

.PARAMETER Workflow
    Workflow identifier; recorded as the active workflow.

.PARAMETER Stack
    Stack identifier(s); recorded as active stacks. Accepts a comma-
    separated string or multiple -Stack values.

.PARAMETER Force
    Refresh the workflow/stack selection in .bot/.control/settings.json
    and rewrite .bot/.gitignore. Workspace data under .bot/workspace/ is
    never touched.

.PARAMETER CopyRuntime
    Copy the framework runtime into .bot/runtime. Re-run with -Force
    to refresh an existing project-local copy.

.PARAMETER DryRun
    Preview without writing.

.PARAMETER AssumeYes
    Answer yes to confirmation prompts. Alias: -y.

.EXAMPLE
    dotbot init
.EXAMPLE
    dotbot init -Workflow start-from-jira -Stack dotnet,dotnet-ef
#>

[CmdletBinding()]
param(
    [string]$Workflow,
    [string[]]$Stack,
    [Alias('copy-runtime')]
    [switch]$CopyRuntime,
    [switch]$Force,
    [Alias('dry-run')]
    [switch]$DryRun,
    [Alias('y', 'yes')]
    [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'
# Reset strict mode — callers may set Set-StrictMode -Version Latest which
# would otherwise propagate here and break intrinsic .Count on non-collection
# types like [string].
Set-StrictMode -Off

if ($AssumeYes) { $env:DOTBOT_ASSUME_YES = '1' }

# ---------------------------------------------------------------------------
# DOTBOT_HOME validation
# ---------------------------------------------------------------------------
$dotbotHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
if ([string]::IsNullOrWhiteSpace($dotbotHome)) {
    [Console]::Error.WriteLine('ERROR: DOTBOT_HOME is not set.')
    [Console]::Error.WriteLine('Set it to your dotbot checkout, e.g.')
    [Console]::Error.WriteLine("  `$env:DOTBOT_HOME = '<path/to/dotbot>'")
    exit 1
}

$dotbotHome = $dotbotHome.Trim()
if ($dotbotHome -eq '~') {
    $dotbotHome = $HOME
} elseif ($dotbotHome.StartsWith('~/') -or $dotbotHome.StartsWith('~\')) {
    $dotbotHome = Join-Path $HOME $dotbotHome.Substring(2)
}

try {
    $resolvedHome = [System.IO.Path]::GetFullPath($dotbotHome)
} catch {
    [Console]::Error.WriteLine("ERROR: DOTBOT_HOME is not a usable path: $dotbotHome")
    exit 1
}

if (-not (Test-Path -LiteralPath $resolvedHome -PathType Container)) {
    [Console]::Error.WriteLine("ERROR: DOTBOT_HOME does not exist: $resolvedHome")
    exit 1
}

$cliMarker = Join-Path $resolvedHome 'bin/dotbot.ps1'
$contentMarker = Join-Path $resolvedHome 'content/workspace-template'
if (-not (Test-Path -LiteralPath $cliMarker) -or -not (Test-Path -LiteralPath $contentMarker)) {
    [Console]::Error.WriteLine("ERROR: DOTBOT_HOME does not look like a dotbot checkout: $resolvedHome")
    [Console]::Error.WriteLine("Expected bin/dotbot.ps1 and content/workspace-template/ to exist.")
    exit 1
}

# ---------------------------------------------------------------------------
# Module imports (theme + helpers come from DOTBOT_HOME)
# ---------------------------------------------------------------------------
Import-Module (Join-Path $resolvedHome 'src/cli/Platform-Functions.psm1') -Force
Import-Module (Join-Path $resolvedHome 'src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $resolvedHome 'src/runtime/Modules/Dotbot.LegacyYaml/Dotbot.LegacyYaml.psd1') -Force -DisableNameChecking

$ProjectDir = (Get-Location).Path
$BotDir     = Join-Path $ProjectDir '.bot'

Write-DotbotBanner -Title 'D O T B O T' -Subtitle 'Project Initialization'

# ---------------------------------------------------------------------------
# Pre-conditions: git installed, project under git, .bot guard
# ---------------------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-DotbotError 'Git is required but not installed.'
    Write-DotbotCommand 'Download from: https://git-scm.com/downloads'
    exit 1
}

if (-not (Test-Path (Join-Path $ProjectDir '.git'))) {
    Write-DotbotWarning 'Current directory is not a git repository.'
    $initGit = Read-DotbotConfirmation -Message 'Initialize a git repository here?' -Default $false
    if (-not $initGit) {
        Write-DotbotCommand 'Run git init explicitly before dotbot init.'
        exit 1
    }

    if ($DryRun) {
        Write-DotbotWarning 'Dry run — would run git init'
    } else {
        & git init --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $ProjectDir '.git'))) {
            Write-DotbotError 'Failed to initialize git repository.'
            exit 1
        }
        Write-Success 'Initialized git repository'
    }
}

# ---------------------------------------------------------------------------
# Legacy v3.5 YAML manifest migration offer
# ---------------------------------------------------------------------------
$legacyYamlFiles = @(Get-DotbotLegacyYamlFile -BotRoot $BotDir)
if ($legacyYamlFiles.Count -gt 0) {
    Write-DotbotWarning 'Legacy v3.5 YAML manifests found:'
    foreach ($file in $legacyYamlFiles) {
        Write-DotbotCommand "  $file"
    }
    if ($DryRun) {
        Write-DotbotWarning 'Dry run — would convert these to the v4 JSON layout'
    } elseif (Read-DotbotConfirmation -Message 'Convert them to the v4 JSON layout now?' -Default $true) {
        Invoke-DotbotWorkflowYamlMigration -BotRoot $BotDir -Force
        Write-Success 'Legacy YAML migration finished'
        Write-DotbotCommand 'Review the changes and commit them if .bot/ is tracked.'
    } else {
        Write-DotbotWarning 'dotbot v4 does not read YAML manifests — these workflows stay invisible until converted. See MIGRATING.md.'
    }
    Write-BlankLine
}

if ((Test-Path $BotDir) -and -not $Force) {
    Write-DotbotWarning '.bot directory already exists — use -Force to refresh selections'
    Write-BlankLine
    exit 1
}

Write-Status   "Initializing .bot in: $ProjectDir"
Write-DotbotCommand "Using DOTBOT_HOME: $resolvedHome"
if ($CopyRuntime) {
    Write-DotbotCommand "Copying runtime into: .bot/runtime"
}

if ($DryRun) {
    Write-BlankLine
    Write-DotbotWarning 'Dry run — no files written'
    exit 0
}

# ---------------------------------------------------------------------------
# .bot/workspace seed
# ---------------------------------------------------------------------------
if (-not (Test-Path $BotDir)) {
    New-Item -ItemType Directory -Path $BotDir -Force | Out-Null
}

$workspaceTemplate = Join-Path $resolvedHome 'content/workspace-template'
$workspaceDest     = Join-Path $BotDir 'workspace'
if (-not (Test-Path $workspaceDest)) {
    New-Item -ItemType Directory -Path $workspaceDest -Force | Out-Null
}

# Seed from template (skips when target file already exists so -Force keeps
# user-edited content).
Get-ChildItem -Path $workspaceTemplate -Force -Recurse -File | ForEach-Object {
    $full = [System.IO.Path]::GetFullPath($_.FullName)
    $rel  = [System.IO.Path]::GetRelativePath([System.IO.Path]::GetFullPath($workspaceTemplate), $full)
    $dest = Join-Path $workspaceDest $rel
    if (Test-Path -LiteralPath $dest) { return }
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -Path $_.FullName -Destination $dest -Force
}

# Standard workspace subtree (forward slashes — Join-Path is cross-platform;
# backslashes would be literal on Linux/macOS).
$workspaceDirs = @(
    'tasks/workflow-runs',
    'tasks/standalone',
    'sessions/runs',
    'sessions/history',
    'plans',
    'product',
    'decisions/accepted',
    'decisions/deprecated',
    'decisions/proposed',
    'decisions/superseded',
    'pilot',
    'reports'
)
foreach ($rel in $workspaceDirs) {
    $abs = Join-Path $workspaceDest $rel
    if (-not (Test-Path $abs)) {
        New-Item -ItemType Directory -Path $abs -Force | Out-Null
    }
    $gitkeep = Join-Path $abs '.gitkeep'
    if (-not (Test-Path $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# .bot/.gitignore
# ---------------------------------------------------------------------------
$botGitignore = @'
# Runtime state and machine-local signals
.control/
.handoffs/
.chrome-dev/
.dev-pids.json

# Autonomous-execution session run logs
workspace/sessions/runs/

# Project-local runtime state
runtime/.studio-port
'@
Set-Content -Path (Join-Path $BotDir '.gitignore') -Value $botGitignore -Encoding UTF8

Write-Success 'Created .bot/workspace tree and .bot/.gitignore'

# ---------------------------------------------------------------------------
# Optional project-local runtime
# ---------------------------------------------------------------------------
function Copy-DotbotDirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('.git', '.bot', 'node_modules') } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
        }
}

function Remove-LegacyDotbotRuntimeMarker {
    param([Parameter(Mandatory)][string]$Root)

    Get-ChildItem -LiteralPath $Root -Force -Recurse -File -Filter '.dotbot-runtime.json' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Copy-DotbotProjectRuntime {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    $runtimeRoot = Join-Path $BotRoot 'runtime'

    if (Test-Path -LiteralPath $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

    $directorySpecs = @(
        @{ Source = 'bin';         Destination = 'bin' },
        @{ Source = 'content';     Destination = 'content' },
        @{ Source = 'src/cli';     Destination = 'src/cli' },
        @{ Source = 'src/hooks';   Destination = 'src/hooks' },
        @{ Source = 'src/mcp';     Destination = 'src/mcp' },
        @{ Source = 'src/runtime'; Destination = 'src/runtime' },
        @{ Source = 'src/shared';  Destination = 'src/shared' },
        @{ Source = 'src/ui';      Destination = 'src/ui' },
        @{ Source = 'registries';  Destination = 'registries' }
    )

    foreach ($spec in $directorySpecs) {
        $source = Join-Path $SourceRoot $spec.Source
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        $destination = Join-Path $runtimeRoot $spec.Destination
        Copy-DotbotDirectoryContents -Source $source -Destination $destination
    }

    foreach ($fileName in @('version.json')) {
        $sourceFile = Join-Path $SourceRoot $fileName
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { continue }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $runtimeRoot $fileName) -Force
    }

    Remove-LegacyDotbotRuntimeMarker -Root $runtimeRoot

    $runtimeCli = Join-Path $runtimeRoot 'bin/dotbot.ps1'
    $runtimeWorkspace = Join-Path $runtimeRoot 'content' 'workspace-template'
    if (-not (Test-Path -LiteralPath $runtimeCli -PathType Leaf) -or
        -not (Test-Path -LiteralPath $runtimeWorkspace -PathType Container)) {
        throw "Project-local dotbot runtime is incomplete at $runtimeRoot"
    }

    return $runtimeRoot
}

if ($CopyRuntime) {
    try {
        $runtimeRoot = Copy-DotbotProjectRuntime -SourceRoot $resolvedHome -BotRoot $BotDir
        Write-Success "Copied runtime: .bot/runtime"
    } catch {
        Write-DotbotError "Failed to copy dotbot runtime: $($_.Exception.Message)"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Workflow / Stack selection
# ---------------------------------------------------------------------------
function Test-OverrideSubtree {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    $overridesDir = Join-Path $Dir 'overrides'
    if (-not (Test-Path $overridesDir)) { return $false }
    return (@(Get-ChildItem $overridesDir -Recurse -File -ErrorAction SilentlyContinue)).Count -gt 0
}

function Copy-EffectiveOverrideContent {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$TargetDir
    )
    if (Test-Path -LiteralPath $TargetDir) {
        Remove-Item -LiteralPath $TargetDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    $sourceFull = [System.IO.Path]::GetFullPath($SourceDir)
    Get-ChildItem -Path $SourceDir -Recurse -File | Where-Object {
        $rel = [System.IO.Path]::GetRelativePath($sourceFull, [System.IO.Path]::GetFullPath($_.FullName))
        -not ($rel -eq 'overrides' -or $rel.StartsWith("overrides$([System.IO.Path]::DirectorySeparatorChar)"))
    } | ForEach-Object {
        $rel  = [System.IO.Path]::GetRelativePath($sourceFull, [System.IO.Path]::GetFullPath($_.FullName))
        $dest = Join-Path $TargetDir $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
    $overridesDir = Join-Path $SourceDir 'overrides'
    if (-not (Test-Path $overridesDir)) { return }
    $overridesFull = [System.IO.Path]::GetFullPath($overridesDir)
    Get-ChildItem -Path $overridesDir -Recurse -File | ForEach-Object {
        $rel  = [System.IO.Path]::GetRelativePath($overridesFull, [System.IO.Path]::GetFullPath($_.FullName))
        $dest = Join-Path $TargetDir $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
}

function Resolve-FrameworkSource {
    param(
        [Parameter(Mandatory)][ValidateSet('workflows','stacks')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DotbotHome
    )
    if ($Name -match '^([^:]+):(.+)$') {
        $ns = $Matches[1]; $short = $Matches[2]
        $candidate = Join-Path $DotbotHome 'registries' $ns $Kind $short
        if (Test-Path $candidate) { return @{ Path = $candidate; Display = $short; Registry = $true } }
        return $null
    }
    $candidate = Join-Path $DotbotHome 'content' $Kind $Name
    if (Test-Path $candidate) { return @{ Path = $candidate; Display = $Name; Registry = $false } }
    return $null
}

$resolvedWorkflow = $null
$resolvedStacks   = @()

if ($Workflow) {
    $wf = Resolve-FrameworkSource -Kind 'workflows' -Name $Workflow -DotbotHome $resolvedHome
    if (-not $wf) {
        Write-DotbotError "Workflow not found in DOTBOT_HOME: $Workflow"
        exit 1
    }
    $resolvedWorkflow = $wf.Display
    if ((Test-OverrideSubtree -Dir $wf.Path) -or $wf.Registry) {
        $target = Join-Path $BotDir 'content' 'workflows' $wf.Display
        Copy-EffectiveOverrideContent -SourceDir $wf.Path -TargetDir $target
        Write-DotbotCommand "Materialised workflow → .bot/content/workflows/$($wf.Display)/"
    }
}

if ($Stack -and $Stack.Count -gt 0) {
    $requested = @()
    foreach ($entry in $Stack) {
        foreach ($token in ($entry -split ',')) {
            $trimmed = $token.Trim()
            if ($trimmed) { $requested += $trimmed }
        }
    }
    $seen = @{}
    function Add-SelectedStack {
        param([Parameter(Mandatory)][string]$Name)
        $st = Resolve-FrameworkSource -Kind 'stacks' -Name $Name -DotbotHome $resolvedHome
        if (-not $st) {
            Write-DotbotError "Stack not found in DOTBOT_HOME: $Name"
            exit 1
        }
        $manifest = Join-Path $st.Path 'manifest.json'
        if (Test-Path -LiteralPath $manifest) {
            try {
                $manifestData = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
                if ($manifestData.extends) { Add-SelectedStack -Name "$($manifestData.extends)" }
            } catch {
                Write-DotbotError "Failed to parse stack manifest at '$manifest': $($_.Exception.Message)"
                exit 1
            }
        }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $script:resolvedStacks += $st.Display
        if ((Test-OverrideSubtree -Dir $st.Path) -or $st.Registry) {
            $target = Join-Path $BotDir 'content' 'stacks' $st.Display
            Copy-EffectiveOverrideContent -SourceDir $st.Path -TargetDir $target
            Write-DotbotCommand "Materialised stack → .bot/content/stacks/$($st.Display)/"
        }
    }
    foreach ($name in $requested) {
        Add-SelectedStack -Name $name
    }
}

# Record selections in .bot/.control/settings.json (per-machine, gitignored).
# Lazy-created — bare `dotbot init` never produces this file.
if ($resolvedWorkflow -or $resolvedStacks.Count -gt 0) {
    $controlDir = Join-Path $BotDir '.control'
    if (-not (Test-Path $controlDir)) {
        New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
    }
    $controlSettingsPath = Join-Path $controlDir 'settings.json'
    $existing = [pscustomobject]@{}
    if (Test-Path $controlSettingsPath) {
        try { $existing = Get-Content $controlSettingsPath -Raw | ConvertFrom-Json } catch {
            $existing = [pscustomobject]@{}
        }
    }
    if ($resolvedWorkflow) {
        $existing | Add-Member -NotePropertyName 'workflow' -NotePropertyValue $resolvedWorkflow -Force
    }
    if ($resolvedStacks.Count -gt 0) {
        $existing | Add-Member -NotePropertyName 'stacks' -NotePropertyValue $resolvedStacks -Force
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content -Path $controlSettingsPath -Encoding UTF8

    if ($resolvedWorkflow)        { Write-Success "Active workflow: $resolvedWorkflow" }
    if ($resolvedStacks.Count -gt 0) { Write-Success "Active stacks:  $($resolvedStacks -join ', ')" }
}

# ---------------------------------------------------------------------------
# Completion banner
# ---------------------------------------------------------------------------
Write-BlankLine
Write-DotbotBanner -Title 'Project Initialized'
Write-DotbotSection -Title 'WHAT WAS CREATED'
Write-DotbotLabel -Label '.bot/workspace/  ' -Value 'project task + decision tree (tracked)'
Write-DotbotLabel -Label '.bot/.gitignore  ' -Value 'machine-local paths under .bot/'
if ($CopyRuntime) {
    Write-DotbotLabel -Label '.bot/runtime/    ' -Value 'project-local dotbot runtime'
}
if ($resolvedWorkflow -or $resolvedStacks.Count -gt 0) {
    Write-DotbotLabel -Label '.bot/.control/   ' -Value 'workflow + stack selections (gitignored)'
}
Write-BlankLine
Write-DotbotSection -Title 'NEXT STEPS'
Write-DotbotLabel -Label '1. Go      ' -Value 'dotbot go'
Write-DotbotLabel -Label '2. Verify  ' -Value 'dotbot doctor'
Write-BlankLine
