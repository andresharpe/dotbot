#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests for #366: dotbot MCP server returns full tool schemas eagerly.
.DESCRIPTION
    The Claude Code harness is free to defer tool schemas to save context
    budget; that decision lives entirely in the harness, not the dotbot
    MCP server. This test locks in the contract on dotbot's side: the
    `tools/list` response must include every registered tool with a full
    inputSchema and a non-empty description, and the server must not set
    any deferral hint in its `initialize` capabilities.

    If the harness still defers dotbot tools despite this contract, that
    is out of scope for the dotbot repo (per #366's verification section).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host "  MCP Handshake — Eager Schema Contract" -ForegroundColor Blue
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$proj = New-TestProjectFromGolden -Flavor 'default'
$testProject = $proj.ProjectRoot
$botDir = Join-Path $testProject ".bot"

$mcpProcess = $null
try {
    $mcpProcess = Start-McpServer -BotDir $botDir
    Assert-True -Name "MCP server starts" `
        -Condition (-not $mcpProcess.HasExited) `
        -Message "Server process exited immediately"

    $initResponse = Send-McpInitialize -Process $mcpProcess
    Assert-True -Name "initialize responds with a result" `
        -Condition ($null -ne $initResponse -and $null -ne $initResponse.result) `
        -Message "Expected initialize to return a result"

    if ($initResponse -and $initResponse.result) {
        $caps = $initResponse.result.capabilities
        Assert-True -Name "capabilities exist on initialize response" `
            -Condition ($null -ne $caps) `
            -Message "Expected capabilities on initialize response"

        # No deferral hint anywhere in capabilities. The MCP 2024-11-05 spec
        # has no notion of deferral; this guards against a future addition
        # accidentally enabling per-tool deferral on dotbot's side.
        $capsJson = $caps | ConvertTo-Json -Depth 10 -Compress
        Assert-True -Name "capabilities does not advertise deferral" `
            -Condition (-not ($capsJson -match '(?i)defer')) `
            -Message "Expected no defer/deferred/deferral hint in capabilities; got: $capsJson"
    }

    $listResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = 1
        method  = 'tools/list'
        params  = @{}
    }

    Assert-True -Name "tools/list responds with a result" `
        -Condition ($null -ne $listResponse -and $null -ne $listResponse.result) `
        -Message "Expected tools/list to return a result"

    if ($listResponse -and $listResponse.result) {
        $tools = @($listResponse.result.tools)
        Assert-True -Name "tools/list returns one or more tools" `
            -Condition ($tools.Count -gt 0) `
            -Message "Expected tools/list to return at least one tool, got $($tools.Count)"

        # Every dotbot tool must come back with a full inputSchema and a
        # non-empty description. Any missing schema would force the prompts
        # to fall back to ToolSearch.
        $missingSchema = @()
        $missingDescription = @()
        $hasDeferralFlag = @()
        foreach ($t in $tools) {
            $schema = $t.inputSchema
            if (-not $schema -or $null -eq $schema.type) {
                $missingSchema += $t.name
            }
            if (-not $t.description -or "$($t.description)".Trim().Length -eq 0) {
                $missingDescription += $t.name
            }
            $toolJson = $t | ConvertTo-Json -Depth 10 -Compress
            # Fail on the *presence* of a defer/deferred key regardless of
            # its value. A `false` still advertises a deferral concept the
            # dotbot tool list should not carry.
            if ($toolJson -match '(?i)"defer"\s*:' -or $toolJson -match '(?i)"deferred"\s*:') {
                $hasDeferralFlag += $t.name
            }
        }

        Assert-True -Name "every tool has a non-empty inputSchema" `
            -Condition ($missingSchema.Count -eq 0) `
            -Message "Tools without inputSchema: $($missingSchema -join ', ')"
        Assert-True -Name "every tool has a non-empty description" `
            -Condition ($missingDescription.Count -eq 0) `
            -Message "Tools without description: $($missingDescription -join ', ')"
        Assert-True -Name "no tool advertises a deferral flag" `
            -Condition ($hasDeferralFlag.Count -eq 0) `
            -Message "Tools with deferral flag: $($hasDeferralFlag -join ', ')"

        # Spot-check the canonical tools the prompts reference.
        $toolNames = $tools | ForEach-Object { $_.name }
        $canonicalTools = @(
            'task_get_context', 'task_mark_in_progress', 'task_mark_done',
            'task_mark_skipped', 'task_mark_needs_input', 'task_mark_analysed',
            'plan_get', 'plan_create', 'steering_heartbeat',
            'decision_create', 'decision_get', 'decision_list',
            'decision_update', 'task_create_bulk'
        )
        foreach ($expected in $canonicalTools) {
            Assert-True -Name "tools/list contains '$expected' with a schema" `
                -Condition ($expected -in $toolNames) `
                -Message "Expected '$expected' in the tools/list response"
        }

        # Asserts that the inputSchema for at least one canonical tool has the
        # `properties` and `required` fields the prompts depend on. If the
        # server stopped sending these, ToolSearch would still be needed.
        $sample = $tools | Where-Object { $_.name -eq 'task_mark_done' } | Select-Object -First 1
        if ($sample) {
            Assert-True -Name "task_mark_done schema includes a properties object" `
                -Condition ($null -ne $sample.inputSchema.properties) `
                -Message "Expected non-null properties in task_mark_done.inputSchema"
            Assert-True -Name "task_mark_done schema includes a non-empty required array" `
                -Condition ((
                    $sample.inputSchema.required -is [array] -or
                    $sample.inputSchema.required -is [System.Collections.IList]
                ) -and $sample.inputSchema.required.Count -gt 0) `
                -Message "Expected required to be a non-empty array/list in task_mark_done.inputSchema"
        }
    }
}
finally {
    if ($mcpProcess) { Stop-McpServer -Process $mcpProcess }
    if ($testProject -and (Test-Path $testProject)) { Remove-TestProject -Path $testProject }
}

$allPassed = Write-TestSummary -LayerName "MCP Handshake — Eager Schema Contract"

if (-not $allPassed) {
    exit 1
}
