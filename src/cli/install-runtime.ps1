#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install the dotbot runtime into an existing project's .bot/runtime.

.DESCRIPTION
    Copies the framework runtime into .bot/runtime without re-running
    project initialization. This command intentionally touches only the
    project-local runtime tree.

.PARAMETER From
    Optional source dotbot checkout. Defaults to the currently effective
    dotbot checkout.
#>

[CmdletBinding()]
param(
    [string]$From
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Import-Module (Join-Path $PSScriptRoot '..' 'runtime' 'Modules' 'Dotbot.Core' 'Dotbot.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Platform-Functions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'runtime' 'Modules' 'Dotbot.Theme' 'Dotbot.Theme.psd1') -Force -DisableNameChecking

function Resolve-DotbotRuntimeSource {
    param([string]$RequestedSource)

    $source = $RequestedSource
    if ([string]::IsNullOrWhiteSpace($source)) {
        $machineHome = [Environment]::GetEnvironmentVariable('DOTBOT_MACHINE_HOME')
        if (-not [string]::IsNullOrWhiteSpace($machineHome)) {
            $source = $machineHome
        } else {
            $source = Get-DotbotInstallPath
        }
    }

    $source = $source.Trim()
    if ($source -eq '~') {
        $source = $HOME
    } elseif ($source.StartsWith('~/') -or $source.StartsWith('~\')) {
        $source = Join-Path $HOME $source.Substring(2)
    }

    try {
        $source = [System.IO.Path]::GetFullPath($source)
    } catch {
        throw "Runtime source is not a usable path: $source"
    }

    $cli = Join-Path $source 'bin' 'dotbot.ps1'
    $workspaceTemplate = Join-Path $source 'content' 'workspace-template'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf) -or
        -not (Test-Path -LiteralPath $workspaceTemplate -PathType Container)) {
        throw "Runtime source does not look like a dotbot checkout: $source"
    }

    return $source
}

function Find-DotbotProjectBotDir {
    param([string]$StartDir)

    $dir = [System.IO.Path]::GetFullPath($StartDir)
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $candidate = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { break }

        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

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

function Copy-DotbotRuntimeToDirectory {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

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
        $destination = Join-Path $DestinationRoot $spec.Destination
        Copy-DotbotDirectoryContents -Source $source -Destination $destination
    }

    foreach ($fileName in @('version.json')) {
        $sourceFile = Join-Path $SourceRoot $fileName
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { continue }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $DestinationRoot $fileName) -Force
    }

    Remove-LegacyDotbotRuntimeMarker -Root $DestinationRoot

    $runtimeCli = Join-Path $DestinationRoot 'bin' 'dotbot.ps1'
    $runtimeWorkspace = Join-Path $DestinationRoot 'content' 'workspace-template'
    if (-not (Test-Path -LiteralPath $runtimeCli -PathType Leaf) -or
        -not (Test-Path -LiteralPath $runtimeWorkspace -PathType Container)) {
        throw "Copied runtime is incomplete at $DestinationRoot"
    }
}

$botDir = Find-DotbotProjectBotDir -StartDir (Get-Location).Path
if (-not $botDir) {
    Write-DotbotError "Project is not initialized."
    Write-DotbotCommand "Run 'dotbot init' first, or run this from a directory under an existing .bot/."
    exit 1
}

try {
    $sourceRoot = Resolve-DotbotRuntimeSource -RequestedSource $From
} catch {
    Write-DotbotError $_.Exception.Message
    exit 1
}

$targetRoot = Join-Path $botDir 'runtime'
$sourceFull = [System.IO.Path]::GetFullPath($sourceRoot)
$targetFull = [System.IO.Path]::GetFullPath($targetRoot)
if ($sourceFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -eq
    $targetFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) {
    Write-DotbotError "Refusing to install runtime from the same .bot/runtime directory."
    Write-DotbotCommand "Use 'dotbot install runtime --from <dotbot-checkout>' to refresh this project-local copy."
    exit 1
}

if (Test-Path -LiteralPath $targetRoot) {
    Write-DotbotWarning "Runtime is already installed at .bot/runtime."
    $replaceRuntime = Read-DotbotConfirmation -Message 'Replace the installed runtime?' -Default $false
    if (-not $replaceRuntime) {
        Write-DotbotCommand "Runtime install unchanged."
        exit 0
    }
}

Write-DotbotBanner -Title 'D O T B O T' -Subtitle 'Runtime Install'
Write-Status "Project .bot: $botDir"
Write-DotbotCommand "Source: $sourceRoot"

$stagingRoot = Join-Path $botDir ".runtime-install-$([guid]::NewGuid().ToString('N'))"
try {
    Copy-DotbotRuntimeToDirectory -SourceRoot $sourceRoot -DestinationRoot $stagingRoot

    if (Test-Path -LiteralPath $targetRoot) {
        $backupRoot = Join-Path $botDir "runtime.backup-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        Move-Item -LiteralPath $targetRoot -Destination $backupRoot -Force
        Write-DotbotCommand "Previous runtime moved to: $([System.IO.Path]::GetRelativePath($botDir, $backupRoot))"
    }

    Move-Item -LiteralPath $stagingRoot -Destination $targetRoot -Force
    Write-Success "Runtime installed at .bot/runtime"
} catch {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-DotbotError "Failed to install runtime: $($_.Exception.Message)"
    exit 1
}
