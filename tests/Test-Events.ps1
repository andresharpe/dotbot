#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Dotbot.Events sink-discovery tests.
.DESCRIPTION
    Covers the discovery surface of Dotbot.Events (parity with the Dotbot.Hook
    engine):

      - Folder-per-sink discovery: metadata.json + script.ps1, sorted by folder
        name, records carry the expected shape.
      - Event routing: Get-SinksForEvent matches a concrete dotted event type
        against each sink's subscribed_events glob patterns.
      - Fail-loud validation: malformed sink metadata throws rather than being
        silently skipped, so one bad sink among valid ones fails the whole
        registry scan at startup.

    No installed dotbot needed (module is imported directly from src/).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Dotbot.Events — Sink Discovery" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Events/Dotbot.Events.psd1") -Force -DisableNameChecking -Global

# Small helper: assert a scriptblock throws and (optionally) message matches a pattern.
function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$Pattern
    )
    $threw = $false
    $msg = ''
    try { & $Action } catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) {
        Write-TestResult -Name $Name -Status Fail -Message "Expected an exception, got none."
        return
    }
    if ($Pattern -and ($msg -notmatch $Pattern)) {
        Write-TestResult -Name $Name -Status Fail -Message "Exception '$msg' did not match pattern '$Pattern'."
        return
    }
    Write-TestResult -Name $Name -Status Pass
}

# ───────────────────────────────────────────────────────────────────────────
# Fixture helpers
# ───────────────────────────────────────────────────────────────────────────

function New-SinksRoot {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-sinks-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-SinkFixture {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Name,
        [object]$Metadata,          # hashtable to serialize, or a raw string for malformed-JSON cases
        [switch]$NoMetadata,
        [switch]$NoScript,
        [string]$RawMetadata
    )
    $sinkDir = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $sinkDir -Force | Out-Null

    if (-not $NoMetadata) {
        $metaPath = Join-Path $sinkDir 'metadata.json'
        if ($PSBoundParameters.ContainsKey('RawMetadata')) {
            Set-Content -LiteralPath $metaPath -Value $RawMetadata -Encoding utf8NoBOM
        } else {
            ($Metadata | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $metaPath -Encoding utf8NoBOM
        }
    }
    if (-not $NoScript) {
        $scriptPath = Join-Path $sinkDir 'script.ps1'
        Set-Content -LiteralPath $scriptPath -Encoding utf8NoBOM -Value @'
function Invoke-Sink { param($Event) }
Export-ModuleMember -Function Invoke-Sink
'@
    }
    return $sinkDir
}

# ═══════════════════════════════════════════════════════════════════════════
# Happy-path discovery
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Discovery" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$root = New-SinksRoot
try {
    New-SinkFixture -Root $root -Name 'alpha' -Metadata @{ name = 'alpha'; description = 'A sink'; subscribed_events = @('task.*'); max_duration = 10 } | Out-Null
    New-SinkFixture -Root $root -Name 'zeta'  -Metadata @{ name = 'zeta';  subscribed_events = @('workflow.run_completed', 'task.created'); max_duration = 5 } | Out-Null

    $registry = @(Get-SinkRegistry -SinksDir $root)
    Assert-Equal -Name "registry discovers both sinks" -Expected 2 -Actual $registry.Count
    Assert-Equal -Name "registry is sorted by folder name (alpha first)" -Expected 'alpha' -Actual $registry[0].name
    Assert-Equal -Name "registry is sorted by folder name (zeta second)" -Expected 'zeta'  -Actual $registry[1].name

    $alpha = $registry[0]
    Assert-Equal -Name "alpha carries description"           -Expected 'A sink' -Actual $alpha.description
    Assert-Equal -Name "alpha carries max_duration as int"   -Expected 10       -Actual $alpha.max_duration
    Assert-True  -Name "alpha subscribed_events has task.*"   -Condition ($alpha.subscribed_events -contains 'task.*')
    Assert-True  -Name "alpha record points at its script.ps1" -Condition (Test-Path -LiteralPath $alpha.script_path)
    Assert-True  -Name "alpha record points at its metadata.json" -Condition (Test-Path -LiteralPath $alpha.metadata_path)

    # ── Event routing (glob match) ──
    $forTaskCreated = @(Get-SinksForEvent -Registry $registry -EventType 'task.created')
    Assert-Equal -Name "task.created routes to both (alpha via task.*, zeta via exact)" -Expected 2 -Actual $forTaskCreated.Count

    $forTaskUpdated = @(Get-SinksForEvent -Registry $registry -EventType 'task.updated')
    Assert-Equal -Name "task.updated routes to alpha only (task.* glob)" -Expected 1 -Actual $forTaskUpdated.Count
    Assert-Equal -Name "task.updated matched sink is alpha" -Expected 'alpha' -Actual $forTaskUpdated[0].name

    $forRunCompleted = @(Get-SinksForEvent -Registry $registry -EventType 'workflow.run_completed')
    Assert-Equal -Name "workflow.run_completed routes to zeta only" -Expected 1 -Actual $forRunCompleted.Count
    Assert-Equal -Name "workflow.run_completed matched sink is zeta" -Expected 'zeta' -Actual $forRunCompleted[0].name

    $forDecision = @(Get-SinksForEvent -Registry $registry -EventType 'decision.created')
    Assert-Equal -Name "unsubscribed event routes to no sinks" -Expected 0 -Actual $forDecision.Count
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# ── Empty / missing sinks dir is not an error ──
$missing = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-sinks-none-" + [guid]::NewGuid().ToString('N').Substring(0,8))
Assert-Equal -Name "missing sinks dir yields empty registry (no throw)" -Expected 0 -Actual (@(Get-SinkRegistry -SinksDir $missing)).Count

# ═══════════════════════════════════════════════════════════════════════════
# Fail-loud validation
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Fail-loud validation" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bad = New-SinksRoot
try {
    $d = New-SinkFixture -Root $bad -Name 'no-meta' -NoMetadata
    Assert-Throws -Name "missing metadata.json throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'missing metadata.json'

    $d = New-SinkFixture -Root $bad -Name 'no-script' -Metadata @{ name = 'x'; subscribed_events = @('task.*'); max_duration = 5 } -NoScript
    Assert-Throws -Name "missing script.ps1 throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'missing script.ps1'

    $d = New-SinkFixture -Root $bad -Name 'bad-json' -RawMetadata '{ not valid json ]'
    Assert-Throws -Name "invalid JSON throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'Invalid metadata.json'

    $d = New-SinkFixture -Root $bad -Name 'no-max' -Metadata @{ name = 'x'; subscribed_events = @('task.*') }
    Assert-Throws -Name "missing required field throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern "missing required field 'max_duration'"

    $d = New-SinkFixture -Root $bad -Name 'empty-events' -Metadata @{ name = 'x'; subscribed_events = @(); max_duration = 5 }
    Assert-Throws -Name "empty subscribed_events throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'empty subscribed_events'

    $d = New-SinkFixture -Root $bad -Name 'blank-event' -Metadata @{ name = 'x'; subscribed_events = @('task.*', ''); max_duration = 5 }
    Assert-Throws -Name "blank subscribed_events entry throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'blank entry in subscribed_events'

    $d = New-SinkFixture -Root $bad -Name 'zero-dur' -Metadata @{ name = 'x'; subscribed_events = @('task.*'); max_duration = 0 }
    Assert-Throws -Name "non-positive max_duration throws" -Action { Read-SinkMetadata -SinkDir $d } -Pattern 'non-positive max_duration'
} finally {
    Remove-Item -Recurse -Force $bad -ErrorAction SilentlyContinue
}

# ── One malformed sink among valid ones fails the whole registry scan ──
$mixed = New-SinksRoot
try {
    New-SinkFixture -Root $mixed -Name 'good' -Metadata @{ name = 'good'; subscribed_events = @('task.*'); max_duration = 5 } | Out-Null
    New-SinkFixture -Root $mixed -Name 'broken' -Metadata @{ name = 'broken'; subscribed_events = @('task.*') } | Out-Null  # missing max_duration
    Assert-Throws -Name "Get-SinkRegistry fails loudly when any sink is malformed" -Action { Get-SinkRegistry -SinksDir $mixed } -Pattern "missing required field"
} finally {
    Remove-Item -Recurse -Force $mixed -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Dotbot.Events Sink Discovery"

if (-not $allPassed) {
    exit 1
}
