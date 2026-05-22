#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Copy a built-in (framework-tier) workflow into the project tier.

.DESCRIPTION
    Copies <project>/.bot/content/workflows/<name>/ to
    <project>/.bot/workflows/<name>/ so the user can edit it without their
    changes being overwritten on framework upgrade. After the copy, the
    project-tier copy shadows the framework-tier copy in Find-Workflow's
    resolution order — i.e., dotbot will pick up the project copy on next
    run.

.PARAMETER Name
    Workflow identifier to scaffold (e.g. "start-from-repo").

.PARAMETER Force
    Overwrite an existing project-tier workflow with the same name. Without
    -Force, the command refuses to clobber.
#>
param(
    [Parameter(Position = 0)]
    [string]$Name,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path (Get-DotbotInstallPath) "src\cli\Platform-Functions.psm1") -Force
Import-Module (Join-Path (Get-DotbotInstallPath) "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

if (-not $Name) {
    Write-DotbotWarning "Usage: dotbot workflow scaffold <name> [--Force]"
    Write-DotbotCommand "Example: dotbot workflow scaffold start-from-repo"
    exit 1
}

Import-Module (Join-Path (Get-DotbotProjectRuntimePath) "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psd1") -Force -DisableNameChecking

$roots = Get-WorkflowTierRoots -BotRoot $BotDir
$sourceDir = Join-Path $roots.framework $Name
$targetDir = Join-Path $roots.project $Name

if (-not (Test-ValidWorkflowDir -Dir $sourceDir)) {
    Write-DotbotError "Workflow '$Name' is not present in the framework tier ($($roots.framework))."
    Write-DotbotWarning "Run 'dotbot workflow list' to see what's available."
    exit 1
}

if ((Test-Path $targetDir) -and -not $Force) {
    Write-DotbotError "Project workflow '$Name' already exists at $targetDir."
    Write-DotbotWarning "Re-run with -Force to overwrite, or edit it in place."
    exit 1
}

if (Test-Path $targetDir) {
    Remove-Item -Path $targetDir -Recurse -Force
}

# Ensure project tier root exists.
if (-not (Test-Path $roots.project)) {
    New-Item -Path $roots.project -ItemType Directory -Force | Out-Null
}

Write-Status "Copying framework workflow '$Name' into project tier..."
Copy-Item -Path $sourceDir -Destination $targetDir -Recurse -Force

Write-BlankLine
Write-Success "Copied built-in '$Name' to project."
Write-DotbotCommand "Edit $targetDir/workflow.yaml to customise."
Write-DotbotCommand "The project copy now overrides the framework copy at runtime."
Write-BlankLine
