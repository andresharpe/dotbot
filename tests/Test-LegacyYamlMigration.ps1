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

        foreach ($wrongRoot in @(
            @{ Name = 'scalar'; Content = 'just-a-string' },
            @{ Name = 'sequence'; Content = "- one`n- two" }
        )) {
            $wrongYaml = Join-Path $root "$($wrongRoot.Name).yaml"
            $wrongJson = Join-Path $root "$($wrongRoot.Name).json"
            Set-Content -Path $wrongYaml -Value $wrongRoot.Content
            $wrongThrew = $false
            try {
                Convert-DotbotYamlFileToJson -YamlPath $wrongYaml -JsonPath $wrongJson 6>&1 | Out-Null
            } catch { $wrongThrew = $true }
            Assert-True -Name "$($wrongRoot.Name) YAML root is rejected" -Condition $wrongThrew
            Assert-PathNotExists -Name "$($wrongRoot.Name) YAML writes no JSON" -Path $wrongJson
            Assert-PathExists -Name "$($wrongRoot.Name) YAML remains retryable" -Path $wrongYaml
        }

        $rollbackYaml = Join-Path $root "rollback.yaml"
        $rollbackJson = Join-Path $root "rollback.json"
        Set-Content -Path $rollbackYaml -Value "name: rollback"
        & (Get-Module Dotbot.LegacyYaml) {
            $script:MigrationFailureInjector = {
                param($Operation, $Source, $Destination)
                if ($Operation -eq 'archive-yaml') { throw 'injected archive failure' }
            }
        }
        $rollbackThrew = $false
        try {
            Convert-DotbotYamlFileToJson -YamlPath $rollbackYaml -JsonPath $rollbackJson 6>&1 | Out-Null
        } catch { $rollbackThrew = $true }
        & (Get-Module Dotbot.LegacyYaml) { $script:MigrationFailureInjector = $null }
        Assert-True -Name "Archive failure is surfaced" -Condition $rollbackThrew
        Assert-PathNotExists -Name "Archive failure rolls back published JSON" -Path $rollbackJson
        Assert-PathExists -Name "Archive failure leaves YAML in place" -Path $rollbackYaml
        Assert-PathNotExists -Name "Archive failure creates no misleading backup" -Path "$rollbackYaml.migrated"
        Assert-Equal -Name "Archive failure cleans staged files" -Expected 0 -Actual @(Get-ChildItem $root -Filter 'rollback.json.tmp-*').Count
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

        Set-Content -Path (Join-Path $badDir "workflow.yaml") -Value "name: repaired"
        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot 6>&1 | Out-Null
        Assert-ValidJson -Name "Failed migration retries in the same process after repair" -Path (Join-Path $badDir "workflow.json")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # A failure after the legacy directory move restores the entire v3 layout.
    $root = New-TempRoot -Prefix "dotbot-lym-dirrollback"
    try {
        $bot = Join-Path $root ".bot"
        $legacyDir = Join-Path $bot "workflows/rollback-flow"
        $targetDir = Join-Path $bot "content/workflows/rollback-flow"
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        Set-Content -Path (Join-Path $legacyDir "workflow.yaml") -Value "name: rollback-flow"
        Set-Content -Path (Join-Path $legacyDir "sibling.txt") -Value "preserve me"
        & (Get-Module Dotbot.LegacyYaml) {
            $script:MigrationFailureInjector = {
                param($Operation, $Source, $Destination)
                if ($Operation -eq 'archive-yaml') { throw 'injected directory conversion failure' }
            }
        }
        Invoke-DotbotWorkflowYamlMigration -BotRoot $bot -Force 6>&1 | Out-Null
        & (Get-Module Dotbot.LegacyYaml) { $script:MigrationFailureInjector = $null }
        Assert-PathExists -Name "Failed directory conversion restores legacy directory" -Path $legacyDir
        Assert-PathExists -Name "Directory rollback preserves sibling files" -Path (Join-Path $legacyDir "sibling.txt")
        Assert-PathExists -Name "Directory rollback restores source YAML" -Path (Join-Path $legacyDir "workflow.yaml")
        Assert-PathNotExists -Name "Failed directory conversion leaves no v4 directory" -Path $targetDir
    } finally {
        & (Get-Module Dotbot.LegacyYaml) { $script:MigrationFailureInjector = $null }
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Project workflow discovery must not mutate a linked external directory.
    $root = New-TempRoot -Prefix "dotbot-lym-wflink"
    $link = $null
    try {
        $bot = Join-Path $root ".bot"
        $external = Join-Path $root "external-workflow"
        $link = Join-Path $bot "content/workflows/linked"
        New-Item -ItemType Directory -Path $external -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
        Set-Content -Path (Join-Path $external "workflow.yaml") -Value "name: linked"
        if ($IsWindows) {
            New-Item -ItemType Junction -Path $link -Target $external | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $link -Target $external | Out-Null
        }
        $linkedOutput = Invoke-DotbotWorkflowYamlMigration -BotRoot $bot -Force 6>&1 | Out-String
        Assert-True -Name "Linked project workflow warns and skips" -Condition ($linkedOutput -match 'linked directory')
        Assert-PathExists -Name "Linked project workflow leaves external YAML untouched" -Path (Join-Path $external "workflow.yaml")
        Assert-PathNotExists -Name "Linked project workflow writes no external JSON" -Path (Join-Path $external "workflow.json")
    } finally {
        if ($link -and (Test-Path -LiteralPath $link)) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
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

        @{ registries = @(@{ name = 'acme'; type = 'git'; source = 'test'; auto_update = $false }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root "registries.json")

        Invoke-DotbotRegistryYamlMigration -DotbotBase $root -Force 6>&1 | Out-Null

        Assert-ValidJson -Name "registry.yaml converted to registry.json" -Path (Join-Path $acme "registry.json")
        Assert-PathExists -Name "registry.yaml kept as .migrated" -Path (Join-Path $acme "registry.yaml.migrated")
        $regMeta = Get-Content (Join-Path $acme "registry.json") -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal -Name "Registry name survives conversion" -Expected "acme" -Actual $regMeta.name
        Assert-Equal -Name "Registry content map survives conversion" -Expected "deploy" -Actual $regMeta.content.workflows[0]
        Assert-ValidJson -Name "Nested registry workflow converted" -Path (Join-Path $acme "workflows/deploy/workflow.json")

        $invalidYaml = Join-Path $acme "invalid-registry.yaml"
        $invalidJson = Join-Path $acme "invalid-registry.json"
        Set-Content -Path $invalidYaml -Value "name: invalid-registry"
        $invalidThrew = $false
        try {
            Convert-DotbotYamlFileToJson -YamlPath $invalidYaml -JsonPath $invalidJson -ManifestKind Registry 6>&1 | Out-Null
        } catch { $invalidThrew = $true }
        Assert-True -Name "Registry without content mapping is rejected" -Condition $invalidThrew
        Assert-PathNotExists -Name "Invalid registry publishes no JSON" -Path $invalidJson
        Assert-PathExists -Name "Invalid registry YAML remains retryable" -Path $invalidYaml
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Automatic registry discovery never follows a configured local link.
    $root = New-TempRoot -Prefix "dotbot-lym-reglink"
    try {
        $external = Join-Path $root "external-source"
        $registries = Join-Path $root "home/registries"
        $link = Join-Path $registries "linked"
        New-Item -ItemType Directory -Path (Join-Path $external "workflows/deploy") -Force | Out-Null
        New-Item -ItemType Directory -Path $registries -Force | Out-Null
        "name: linked`ncontent:`n  workflows: [deploy]" | Set-Content (Join-Path $external "registry.yaml")
        "name: deploy" | Set-Content (Join-Path $external "workflows/deploy/workflow.yaml")
        if ($IsWindows) {
            New-Item -ItemType Junction -Path $link -Target $external | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $link -Target $external | Out-Null
        }
        @{ registries = @(@{ name = 'linked'; type = 'local'; source = $external; auto_update = $false }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root "home/registries.json")

        $linkedOutput = Invoke-DotbotRegistryYamlMigration -DotbotBase (Join-Path $root 'home') -Force 6>&1 | Out-String
        Assert-True -Name "Automatic linked registry migration warns and skips" -Condition ($linkedOutput -match 'skipped for linked registry')
        Assert-PathExists -Name "Automatic discovery leaves external YAML untouched" -Path (Join-Path $external "registry.yaml")
        Assert-PathNotExists -Name "Automatic discovery writes no external JSON" -Path (Join-Path $external "registry.json")

        Invoke-DotbotSingleRegistryYamlMigration -RegistryPath $link -AllowExternalLink 6>&1 | Out-Null
        Assert-PathExists -Name "Explicit linked registry update may migrate source" -Path (Join-Path $external "registry.json")
    } finally {
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Only configured registries migrate; unrelated directories stay untouched.
    $root = New-TempRoot -Prefix "dotbot-lym-regscope"
    try {
        $registered = Join-Path $root "registries/registered"
        $unregistered = Join-Path $root "registries/unregistered"
        foreach ($path in @($registered, $unregistered)) {
            New-Item -ItemType Directory -Path (Join-Path $path "workflows/deploy") -Force | Out-Null
            "name: $([IO.Path]::GetFileName($path))`ncontent:`n  workflows: [deploy]" | Set-Content (Join-Path $path "registry.yaml")
            "name: deploy" | Set-Content (Join-Path $path "workflows/deploy/workflow.yaml")
        }
        @{ registries = @(@{ name = 'registered'; type = 'git'; source = 'test'; auto_update = $false }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root "registries.json")
        Invoke-DotbotRegistryYamlMigration -DotbotBase $root -Force 6>&1 | Out-Null
        Assert-PathExists -Name "Configured registry is migrated" -Path (Join-Path $registered "registry.json")
        Assert-PathExists -Name "Unregistered registry YAML is untouched" -Path (Join-Path $unregistered "registry.yaml")
        Assert-PathNotExists -Name "Unregistered registry gets no JSON" -Path (Join-Path $unregistered "registry.json")
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
        @{ registries = @(@{ name = 'acme'; type = 'git'; source = 'test'; auto_update = $false }) } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root "registries.json")
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
`$env:PSModulePath = Join-Path `$PSHOME 'Modules'
Import-Module '$modulePath' -Force -DisableNameChecking
function global:Install-Module { throw 'Install-Module must not be invoked during discovery' }
function global:Install-PSResource { throw 'Install-PSResource must not be invoked during discovery' }
`$env:DOTBOT_HOME = '$fakeHome'
Invoke-DotbotWorkflowYamlMigration -BotRoot '$bot' -Force 6>&1 | ForEach-Object { "`$_" }
exit 0
"@
        $output = & pwsh -NoProfile -Command $script 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        Assert-Equal -Name "Command completes despite missing module" -Expected 0 -Actual $exitCode
        Assert-True -Name "Error names PowerShellGet installation" -Condition ($output -match 'Install-Module powershell-yaml')
        Assert-True -Name "Error names PSResourceGet installation" -Condition ($output -match 'Install-PSResource powershell-yaml')
        Assert-True -Name "Discovery performs no implicit package installation" -Condition ($output -notmatch 'must not be invoked during discovery')
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
