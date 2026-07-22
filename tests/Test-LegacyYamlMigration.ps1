#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit tests for legacy v3.5 YAML manifest migration.
.DESCRIPTION
    Tests Dotbot.LegacyYaml functions directly from repo source: detection,
    YAML-to-JSON conversion, layout migration (.bot/workflows -> .bot/content/workflows,
    base .bot/workflow.yaml), ambiguous yaml+json handling, registry migration,
    idempotency, malformed input, module-unavailable path, and the framework-tier
    detect-only guarantee. Requires the powershell-yaml module (auto-installed by
    the code under test on first use).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot/Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Legacy YAML Migration Unit Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.LegacyYaml/Dotbot.LegacyYaml.psd1") -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot "src/cli/Platform-Functions.psm1") -Force -DisableNameChecking

$savedDotbotHome = $env:DOTBOT_HOME

function New-TempRoot {
    param([string]$Prefix)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "$Prefix-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

$workflowYaml = @"
name: Demo Flow
version: "2.1"
description: A legacy v3.5 workflow
requires:
  env_vars:
    - var: MY_PAT
      name: My PAT
      message: PAT required
tasks:
  - name: Task One
    type: prompt
    workflow: 01-task.md
    priority: 0
  - name: Task Two
    type: barrier
    depends_on:
      - Task One
"@

try {
    # An empty fake framework install so migrations never touch a real ~/dotbot
    $fakeHome = New-TempRoot -Prefix "dotbot-lym-home"
    $env:DOTBOT_HOME = $fakeHome

    # ═══════════════════════════════════════════════════════════════════
    # Convert-DotbotYamlFileToJson
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  Convert-DotbotYamlFileToJson" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $root = New-TempRoot -Prefix "dotbot-lym-conv"
    try {
        $yamlPath = Join-Path $root "workflow.yaml"
        $jsonPath = Join-Path $root "out/workflow.json"
        Set-Content -Path $yamlPath -Value $workflowYaml

        Convert-DotbotYamlFileToJson -YamlPath $yamlPath -JsonPath $jsonPath 6>&1 | Out-Null

        Assert-ValidJson -Name "Conversion writes valid JSON" -Path $jsonPath
        Assert-PathNotExists -Name "Source YAML is renamed away" -Path $yamlPath
        Assert-PathExists -Name "Source YAML kept as .migrated" -Path "$yamlPath.migrated"

        $json = Get-Content $jsonPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Name "Scalar field survives conversion" -Expected "Demo Flow" -Actual $json.name
        Assert-Equal -Name "Quoted scalar survives conversion" -Expected "2.1" -Actual $json.version
        Assert-Equal -Name "Nested requires list survives conversion" -Expected "MY_PAT" -Actual $json.requires.env_vars[0].var
        Assert-Equal -Name "Task list survives conversion" -Expected 2 -Actual $json.tasks.Count
        Assert-Equal -Name "Nested depends_on survives conversion" -Expected "Task One" -Actual $json.tasks[1].depends_on[0]

        $emptyYaml = Join-Path $root "empty.yaml"
        Set-Content -Path $emptyYaml -Value ""
        $threw = $false
        try {
            Convert-DotbotYamlFileToJson -YamlPath $emptyYaml -JsonPath (Join-Path $root "empty.json") 6>&1 | Out-Null
        } catch {
            $threw = $true
        }
        Assert-True -Name "Empty YAML throws instead of writing null JSON" -Condition $threw
        Assert-PathNotExists -Name "Empty YAML writes no JSON" -Path (Join-Path $root "empty.json")
        Assert-PathExists -Name "Empty YAML source left untouched" -Path $emptyYaml
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # Detection: Get-DotbotLegacyYamlFile / Test-DotbotLegacyYamlPresent
    # ═══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  Detection" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $root = New-TempRoot -Prefix "dotbot-lym-detect"
    try {
        $bot = Join-Path $root ".bot"
        New-Item -ItemType Directory -Path $bot -Force | Out-Null

        Assert-True -Name "Empty .bot reports no legacy YAML" -Condition (-not (Test-DotbotLegacyYamlPresent -BotRoot $bot))
        Assert-Equal -Name "Empty .bot enumerates zero files" -Expected 0 -Actual @(Get-DotbotLegacyYamlFile -BotRoot $bot).Count

        Set-Content -Path (Join-Path $bot "workflow.yaml") -Value "name: base"
        New-Item -ItemType Directory -Path (Join-Path $bot "workflows/alpha") -Force | Out-Null
        Set-Content -Path (Join-Path $bot "workflows/alpha/workflow.yaml") -Value "name: alpha"
        New-Item -ItemType Directory -Path (Join-Path $bot "content/workflows/beta") -Force | Out-Null
        Set-Content -Path (Join-Path $bot "content/workflows/beta/manifest.yaml") -Value "name: beta"

        $found = @(Get-DotbotLegacyYamlFile -BotRoot $bot)
        Assert-Equal -Name "All three legacy locations enumerated" -Expected 3 -Actual $found.Count
        Assert-True -Name "Detection reports present" -Condition (Test-DotbotLegacyYamlPresent -BotRoot $bot)
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # Invoke-DotbotWorkflowYamlMigration — happy paths
    # ═══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  Invoke-DotbotWorkflowYamlMigration" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # v4-layout yaml-only dir converts in place and is discovered
    $root = New-TempRoot -Prefix "dotbot-lym-v4stray"
    try {
        $bot = Join-Path $root ".bot"
        $wfDir = Join-Path $bot "content/workflows/stray"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        Set-Content -Path (Join-Path $wfDir "workflow.yaml") -Value $workflowYaml

        $warnings = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1)

        Assert-ValidJson -Name "v4-layout stray YAML converted to workflow.json" -Path (Join-Path $wfDir "workflow.json")
        Assert-PathExists -Name "v4-layout stray source kept as .migrated" -Path (Join-Path $wfDir "workflow.yaml.migrated")
        Assert-True -Name "Migration warning emitted" -Condition (@($warnings | Where-Object { "$_" -match 'Migrated legacy YAML manifest' }).Count -eq 1)

        $discovered = @(Discover-Workflows -BotRoot $bot)
        Assert-True -Name "Converted workflow is discovered by v4 loader" -Condition (@($discovered | Where-Object { $_.name -eq 'stray' }).Count -eq 1)
        Assert-Equal -Name "Discovered manifest carries YAML version" -Expected "2.1" -Actual (@($discovered | Where-Object { $_.name -eq 'stray' })[0].version)
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # json-only project: nothing written, nothing warned
    $root = New-TempRoot -Prefix "dotbot-lym-jsononly"
    try {
        $bot = Join-Path $root ".bot"
        $wfDir = Join-Path $bot "content/workflows/pure"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        Set-Content -Path (Join-Path $wfDir "workflow.json") -Value '{"name":"pure","version":"1.0"}'
        $before = (Get-Item (Join-Path $wfDir "workflow.json")).LastWriteTimeUtc

        $warnings = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1)

        Assert-Equal -Name "JSON-only project emits no warnings" -Expected 0 -Actual $warnings.Count
        Assert-Equal -Name "JSON-only manifest untouched" -Expected $before -Actual (Get-Item (Join-Path $wfDir "workflow.json")).LastWriteTimeUtc
        Assert-PathNotExists -Name "JSON-only project gains no .migrated file" -Path (Join-Path $wfDir "workflow.yaml.migrated")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # yaml + json both present: JSON wins, warning emitted, nothing written
    $root = New-TempRoot -Prefix "dotbot-lym-ambig"
    try {
        $bot = Join-Path $root ".bot"
        $wfDir = Join-Path $bot "content/workflows/dual"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        Set-Content -Path (Join-Path $wfDir "workflow.json") -Value '{"name":"dual","version":"9.9"}'
        Set-Content -Path (Join-Path $wfDir "workflow.yaml") -Value "name: dual`nversion: `"1.1`""

        $warnings = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1)

        Assert-True -Name "Ambiguous state warns loudly" -Condition (@($warnings | Where-Object { "$_" -match 'reads only workflow.json' }).Count -eq 1)
        Assert-PathExists -Name "Ambiguous YAML left untouched" -Path (Join-Path $wfDir "workflow.yaml")
        $manifest = Read-WorkflowManifest -WorkflowDir $wfDir
        Assert-Equal -Name "JSON wins over YAML" -Expected "9.9" -Actual $manifest.version

        $warningsAgain = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot -Force 6>&1)
        Assert-True -Name "Ambiguity warning repeats until resolved" -Condition (@($warningsAgain | Where-Object { "$_" -match 'reads only workflow.json' }).Count -eq 1)
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # legacy .bot/workflows/<name>/ moves whole directory into the v4 layout
    $root = New-TempRoot -Prefix "dotbot-lym-legacydir"
    try {
        $bot = Join-Path $root ".bot"
        $legacyDir = Join-Path $bot "workflows/azure-to-github"
        New-Item -ItemType Directory -Path (Join-Path $legacyDir "prompts") -Force | Out-Null
        Set-Content -Path (Join-Path $legacyDir "workflow.yaml") -Value $workflowYaml
        Set-Content -Path (Join-Path $legacyDir "prompts/01-task.md") -Value "# Task prompt"

        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1 | Out-Null

        $target = Join-Path $bot "content/workflows/azure-to-github"
        Assert-ValidJson -Name "Legacy dir converted in v4 location" -Path (Join-Path $target "workflow.json")
        Assert-PathExists -Name "Sibling prompt file moved with the directory" -Path (Join-Path $target "prompts/01-task.md")
        Assert-PathExists -Name "Legacy source kept as .migrated in new location" -Path (Join-Path $target "workflow.yaml.migrated")
        Assert-PathNotExists -Name "Empty legacy workflows/ parent removed" -Path (Join-Path $bot "workflows")

        $found = Find-Workflow -BotRoot $bot -Name "azure-to-github"
        Assert-True -Name "Migrated legacy workflow resolvable via Find-Workflow" -Condition $found.ok
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # base .bot/workflow.yaml lands in a slug-named v4 directory
    $root = New-TempRoot -Prefix "dotbot-lym-base"
    try {
        $bot = Join-Path $root ".bot"
        New-Item -ItemType Directory -Path $bot -Force | Out-Null
        Set-Content -Path (Join-Path $bot "workflow.yaml") -Value "name: My Flow`nversion: `"3.0`""

        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1 | Out-Null

        Assert-ValidJson -Name "Base manifest converted into slug directory" -Path (Join-Path $bot "content/workflows/my-flow/workflow.json")
        Assert-PathExists -Name "Base manifest kept as .migrated" -Path (Join-Path $bot "workflow.yaml.migrated")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # base manifest without a name falls back to 'default'
    $root = New-TempRoot -Prefix "dotbot-lym-noname"
    try {
        $bot = Join-Path $root ".bot"
        New-Item -ItemType Directory -Path $bot -Force | Out-Null
        Set-Content -Path (Join-Path $bot "workflow.yaml") -Value "version: `"1.0`""

        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1 | Out-Null

        Assert-ValidJson -Name "Nameless base manifest lands in default/" -Path (Join-Path $bot "content/workflows/default/workflow.json")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # manifest.yaml fallback name converts too
    $root = New-TempRoot -Prefix "dotbot-lym-manifest"
    try {
        $bot = Join-Path $root ".bot"
        $wfDir = Join-Path $bot "content/workflows/oldname"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        Set-Content -Path (Join-Path $wfDir "manifest.yaml") -Value "name: oldname`nversion: `"0.9`""

        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1 | Out-Null

        Assert-ValidJson -Name "manifest.yaml fallback converted" -Path (Join-Path $wfDir "workflow.json")
        Assert-PathExists -Name "manifest.yaml kept as .migrated" -Path (Join-Path $wfDir "manifest.yaml.migrated")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # malformed YAML fails loudly without hiding the valid neighbour
    $root = New-TempRoot -Prefix "dotbot-lym-malformed"
    try {
        $bot = Join-Path $root ".bot"
        $badDir = Join-Path $bot "content/workflows/bad"
        $goodDir = Join-Path $bot "content/workflows/good"
        New-Item -ItemType Directory -Path $badDir -Force | Out-Null
        New-Item -ItemType Directory -Path $goodDir -Force | Out-Null
        Set-Content -Path (Join-Path $badDir "workflow.yaml") -Value "foo: [unclosed"
        Set-Content -Path (Join-Path $goodDir "workflow.yaml") -Value "name: good`nversion: `"1.0`""

        $output = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1)

        Assert-PathNotExists -Name "Malformed YAML writes no JSON" -Path (Join-Path $badDir "workflow.json")
        Assert-PathExists -Name "Malformed YAML left untouched" -Path (Join-Path $badDir "workflow.yaml")
        Assert-True -Name "Malformed YAML fails loudly" -Condition (@($output | Where-Object { "$_" -match 'Could not migrate' }).Count -ge 1)
        Assert-ValidJson -Name "Valid neighbour still converts in same run" -Path (Join-Path $goodDir "workflow.json")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # idempotency: -Force re-run converts nothing and stays quiet
    $root = New-TempRoot -Prefix "dotbot-lym-idem"
    try {
        $bot = Join-Path $root ".bot"
        $wfDir = Join-Path $bot "content/workflows/once"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        Set-Content -Path (Join-Path $wfDir "workflow.yaml") -Value "name: once`nversion: `"1.0`""

        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot -Force 6>&1 | Out-Null
        $jsonItem = Get-Item (Join-Path $wfDir "workflow.json")
        $before = $jsonItem.LastWriteTimeUtc

        $second = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot -Force 6>&1)

        Assert-Equal -Name "Forced re-run emits no warnings" -Expected 0 -Actual $second.Count
        Assert-Equal -Name "Forced re-run rewrites nothing" -Expected $before -Actual (Get-Item (Join-Path $wfDir "workflow.json")).LastWriteTimeUtc

        New-Item -ItemType Directory -Path (Join-Path $bot "content/workflows/later") -Force | Out-Null
        Set-Content -Path (Join-Path $bot "content/workflows/later/workflow.yaml") -Value "name: later"
        $third = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1)
        Assert-Equal -Name "Process-scope guard short-circuits without -Force" -Expected 0 -Actual $third.Count
        Assert-PathNotExists -Name "Guarded call converts nothing" -Path (Join-Path $bot "content/workflows/later/workflow.json")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # Registry migration
    # ═══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  Registry migration" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $root = New-TempRoot -Prefix "dotbot-lym-registry"
    try {
        $registriesRoot = Join-Path $root "registries"
        $acme = Join-Path $registriesRoot "acme"
        New-Item -ItemType Directory -Path (Join-Path $acme "workflows/deploy") -Force | Out-Null
        @"
name: acme
display_name: Acme Corp
version: "1.2.0"
content:
  workflows: [deploy]
"@ | Set-Content -Path (Join-Path $acme "registry.yaml")
        Set-Content -Path (Join-Path $acme "workflows/deploy/workflow.yaml") -Value "name: deploy`nversion: `"1.0`""

        Invoke-DotbotRegistryYamlMigration -DotbotBase $root -Force 6>&1 | Out-Null

        Assert-ValidJson -Name "registry.yaml converted to registry.json" -Path (Join-Path $acme "registry.json")
        Assert-PathExists -Name "registry.yaml kept as .migrated" -Path (Join-Path $acme "registry.yaml.migrated")
        $regMeta = Get-Content (Join-Path $acme "registry.json") -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Name "Registry name survives conversion" -Expected "acme" -Actual $regMeta.name
        Assert-Equal -Name "Registry content map survives conversion" -Expected "deploy" -Actual $regMeta.content.workflows[0]
        Assert-ValidJson -Name "Nested registry workflow converted" -Path (Join-Path $acme "workflows/deploy/workflow.json")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # registry yaml + json both present: JSON wins, warning emitted
    $root = New-TempRoot -Prefix "dotbot-lym-regambig"
    try {
        $acme = Join-Path $root "registries/acme"
        New-Item -ItemType Directory -Path $acme -Force | Out-Null
        Set-Content -Path (Join-Path $acme "registry.json") -Value '{"name":"acme","content":{"workflows":["a"]}}'
        Set-Content -Path (Join-Path $acme "registry.yaml") -Value "name: acme"
        $before = (Get-Item (Join-Path $acme "registry.json")).LastWriteTimeUtc

        $warnings = @(Invoke-DotbotRegistryYamlMigration -DotbotBase $root -Force 6>&1)

        Assert-True -Name "Registry ambiguity warns loudly" -Condition (@($warnings | Where-Object { "$_" -match 'reads only registry.json' }).Count -eq 1)
        Assert-Equal -Name "Existing registry.json untouched" -Expected $before -Actual (Get-Item (Join-Path $acme "registry.json")).LastWriteTimeUtc
        Assert-PathExists -Name "Ambiguous registry.yaml left untouched" -Path (Join-Path $acme "registry.yaml")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # Framework tier: detect and warn, never write
    # ═══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  Framework tier" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $root = New-TempRoot -Prefix "dotbot-lym-fw"
    try {
        $fwHome = Join-Path $root "framework"
        $fwDir = Join-Path $fwHome "content/workflows/shipped"
        New-Item -ItemType Directory -Path $fwDir -Force | Out-Null
        Set-Content -Path (Join-Path $fwDir "workflow.yaml") -Value "name: shipped"
        $bot = Join-Path $root ".bot"
        New-Item -ItemType Directory -Path $bot -Force | Out-Null

        $env:DOTBOT_HOME = $fwHome
        $warnings = @(Invoke-DotbotWorkflowYamlMigration -BotRoot $bot -Force 6>&1)
        $env:DOTBOT_HOME = $fakeHome

        Assert-True -Name "Framework-tier YAML warns" -Condition (@($warnings | Where-Object { "$_" -match 'never modifies the framework install' }).Count -eq 1)
        Assert-PathNotExists -Name "Framework tier gets no JSON written" -Path (Join-Path $fwDir "workflow.json")
        Assert-PathExists -Name "Framework-tier YAML not renamed" -Path (Join-Path $fwDir "workflow.yaml")
    } finally {
        $env:DOTBOT_HOME = $fakeHome
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # powershell-yaml unavailable: loud, actionable, non-fatal
    # ═══════════════════════════════════════════════════════════════════

    Write-Host ""
    Write-Host "  Module-unavailable path" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $root = New-TempRoot -Prefix "dotbot-lym-nomod"
    try {
        $bot = Join-Path $root ".bot"
        $wfDir = Join-Path $bot "content/workflows/blocked"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        Set-Content -Path (Join-Path $wfDir "workflow.yaml") -Value "name: blocked"

        $modulePath = Join-Path $repoRoot "src/runtime/Modules/Dotbot.LegacyYaml/Dotbot.LegacyYaml.psd1"
        $script = @"
function global:Get-Module { param([switch]`$ListAvailable, [string[]]`$Name) return `$null }
function global:Install-Module { throw 'install blocked by test' }
Import-Module '$modulePath' -Force -DisableNameChecking
`$env:DOTBOT_HOME = '$fakeHome'
Invoke-DotbotWorkflowYamlMigration -BotRoot '$bot' -Force 6>&1 | ForEach-Object { "`$_" }
exit 0
"@
        $output = & pwsh -NoProfile -Command $script 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        Assert-Equal -Name "Command completes despite missing module" -Expected 0 -Actual $exitCode
        Assert-True -Name "Error names the manual install command" -Condition ($output -match 'Install-Module powershell-yaml -Scope CurrentUser')
        Assert-PathNotExists -Name "No JSON written without the module" -Path (Join-Path $wfDir "workflow.json")
        Assert-PathExists -Name "YAML untouched without the module" -Path (Join-Path $wfDir "workflow.yaml")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    $env:DOTBOT_HOME = $savedDotbotHome
    Remove-Item $fakeHome -Recurse -Force -ErrorAction SilentlyContinue
}

$allPassed = Write-TestSummary -LayerName "Layer 1: Legacy YAML Migration"
if (-not $allPassed) {
    exit 1
}
exit 0
