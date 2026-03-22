#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initialize IDE integrations by copying agents and skills to .claude/, .codex/, and .gemini/ directories.

.DESCRIPTION
    This script bridges the .bot/ system with AI coding CLIs by copying agent and skill
    definitions from .bot/prompts/ to each provider's IDE directory. For non-Claude providers,
    AGENT.md model fields are rewritten to match the provider's default model.

    Idempotent — can be run repeatedly without issues.

.NOTES
    This script should be run from the project root directory.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Get script and project directories
$BotDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $BotDir
$ProvidersDir = Join-Path $BotDir "defaults\providers"

Write-Host "  Initializing IDE integrations..." -ForegroundColor Cyan
Write-Host ""

# Define the provider IDE directories to set up
$providerDirs = @(
    @{ Name = "claude"; Dir = ".claude" }
    @{ Name = "codex";  Dir = ".codex" }
    @{ Name = "gemini"; Dir = ".gemini" }
)

# Load provider configs for model rewriting
$providerConfigs = @{}
if (Test-Path $ProvidersDir) {
    Get-ChildItem $ProvidersDir -Filter "*.json" | ForEach-Object {
        try {
            $config = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $providerConfigs[$config.name] = $config
        } catch {
            Write-Host "  ! Failed to load provider config: $($_.Name)" -ForegroundColor DarkYellow
        }
    }
}

$SourceAgentsDir = Join-Path $BotDir "prompts\agents"
$SourceSkillsDir = Join-Path $BotDir "prompts\skills"

foreach ($provider in $providerDirs) {
    $providerName = $provider.Name
    $ideDir = Join-Path $ProjectRoot $provider.Dir

    # Create IDE directory if it doesn't exist
    if (-not (Test-Path $ideDir)) {
        Write-Host "  Creating $($provider.Dir) directory..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $ideDir | Out-Null
    }

    # Copy agents
    $DestAgentsDir = Join-Path $ideDir "agents"

    if (Test-Path $SourceAgentsDir) {
        if (Test-Path $DestAgentsDir) {
            Remove-Item -Path $DestAgentsDir -Recurse -Force
        }

        Copy-Item -Path $SourceAgentsDir -Destination $DestAgentsDir -Recurse

        # For non-Claude providers, rewrite AGENT.md model fields
        if ($providerName -ne 'claude' -and $providerConfigs.ContainsKey($providerName)) {
            $config = $providerConfigs[$providerName]
            $defaultModelId = $config.models.($config.default_model).id

            Get-ChildItem -Path $DestAgentsDir -Filter "AGENT.md" -Recurse | ForEach-Object {
                $content = Get-Content $_.FullName -Raw
                $content = $content -replace 'model:\s*claude-[^\r\n]+', "model: $defaultModelId"
                Set-Content -Path $_.FullName -Value $content -Encoding utf8NoBOM -NoNewline
            }
        }

        $AgentCount = (Get-ChildItem -Path $DestAgentsDir -Directory).Count
        Write-Host "  + $($provider.Dir): Copied $AgentCount agent(s)" -ForegroundColor Green
    }

    # Copy skills
    $DestSkillsDir = Join-Path $ideDir "skills"

    if (Test-Path $SourceSkillsDir) {
        if (Test-Path $DestSkillsDir) {
            Remove-Item -Path $DestSkillsDir -Recurse -Force
        }

        Copy-Item -Path $SourceSkillsDir -Destination $DestSkillsDir -Recurse

        $SkillCount = (Get-ChildItem -Path $DestSkillsDir -Directory).Count
        Write-Host "  + $($provider.Dir): Copied $SkillCount skill(s)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "  Initialization complete!" -ForegroundColor Green
Write-Host ""
Write-Host "IDE integrations are now available in:" -ForegroundColor Cyan
foreach ($provider in $providerDirs) {
    $ideDir = Join-Path $ProjectRoot $provider.Dir
    Write-Host "  $ideDir" -ForegroundColor White
}
Write-Host ""
Write-Host "Agents and skills are ready for Claude, Codex, and Gemini." -ForegroundColor Cyan
Write-Host ""
