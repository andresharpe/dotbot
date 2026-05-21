#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: UI server smoke test. Boots core/ui/server.ps1 against a golden
    .bot/ snapshot (with a deliberately-sparse task JSON), probes every polled
    endpoint, and asserts 2xx + no `level:Error` entries in the freshly-
    truncated server log.
.DESCRIPTION
    Would have caught the issue-#25 regression: a sparse task JSON missing
    optional fields (workflow, script_path, prompt, questions_resolved) tripped
    StateBuilder.psm1:604 under strict mode 3.0, so /api/state returned 500
    with `Route handler error: The property 'workflow' cannot be found`. This
    test seeds exactly that shape and asserts the route handler still returns
    200 with no error entries in the log.

    Layer 2 weight — needs the global dotbot install and a running pwsh server
    on a free port, but no Claude credentials.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Route Handler Smoke (sparse-fixture regression guard)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

if (-not (Test-Path (Join-Path $dotbotDir "core"))) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail `
        -Message "dotbot not installed globally — run 'pwsh install.ps1' first"
    [void](Write-TestSummary -LayerName "Layer 2: Route Handler Smoke")
    exit 1
}

# Clone a fresh golden .bot/ snapshot. Same helper used by Test-Components.
$proj = New-TestProjectFromGolden -Flavor 'default'
$projectRoot = $proj.ProjectRoot
$botDir = $proj.BotDir
$tasksDir = Join-Path $botDir "workspace/tasks"
$logsDir = Join-Path $botDir ".control/logs"

# ─── Seed sparse + full task JSONs ──────────────────────────────────────
# Sparse: missing workflow, script_path, prompt, applicable_*, questions_resolved.
# This is the shape that tripped StateBuilder.psm1:604 during issue #25 reproduction.
$todoDir = Join-Path $tasksDir "todo"
New-Item -ItemType Directory -Path $todoDir -Force | Out-Null

$sparse = @{
    id = 'smoke-sparse-1'
    name = 'Sparse Smoke Task'
    description = 'Probe Get-BotState with a task missing optional fields'
    status = 'todo'
    priority = 0
    effort = 'XS'
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
}
$sparse | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM -Path (Join-Path $todoDir 'smoke-sparse-1.json')

$full = @{
    id = 'smoke-full-1'
    name = 'Full Smoke Task'
    description = 'Probe Get-BotState with a task having every optional field'
    status = 'todo'
    priority = 1
    effort = 'XS'
    type = 'prompt'
    workflow = 'start-from-prompt'
    script_path = $null
    prompt = 'recipes/prompts/01-plan-product.md'
    dependencies = @()
    questions_resolved = @()
    applicable_agents = @()
    applicable_standards = @()
    reviewer_feedback = @()
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
}
$full | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8NoBOM -Path (Join-Path $todoDir 'smoke-full-1.json')

# ─── Pick a free port and launch the server ─────────────────────────────
function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $port = $l.LocalEndpoint.Port
    $l.Stop()
    return $port
}
$port = Get-FreePort
$baseUrl = "http://localhost:$port"

# Server reads .bot/ relative to the project root. Launch the deployed copy
# under the test project so we exercise the same code path the user hits.
$serverScript = Join-Path $botDir "core/ui/server.ps1"
if (-not (Test-Path $serverScript)) {
    Write-TestResult -Name "Server script available in golden" -Status Fail -Message "Not found: $serverScript"
    Remove-TestProject -Path $projectRoot
    [void](Write-TestSummary -LayerName "Layer 2: Route Handler Smoke")
    exit 1
}

# Make sure the log dir exists and is empty so we can scan deltas.
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
Get-ChildItem -Path $logsDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# Launch server as detached pwsh process. Use Push-Location so the server
# resolves .bot/ relative to the test project, not the test runner's cwd.
Push-Location $projectRoot
$serverProc = Start-Process pwsh `
    -ArgumentList @('-NoProfile', '-File', $serverScript, '-Port', $port) `
    -PassThru -RedirectStandardOutput "$projectRoot/server-stdout.log" -RedirectStandardError "$projectRoot/server-stderr.log"
Pop-Location

try {
    # Wait for the server to start listening.
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $resp = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { $ready = $true; break }
        } catch {
            # not ready yet
        }
    }
    Assert-True -Name "Server starts and serves /" -Condition $ready -Message "Did not reach 200 on $baseUrl/ within 15s"
    if (-not $ready) { return }

    # ─── Probe every polled endpoint ────────────────────────────────────
    $endpoints = @(
        '/api/state',
        '/api/state/poll?timeout=1000',
        '/api/activity/tail',
        '/api/info',
        '/api/git-status',
        '/api/decisions',
        '/api/product/list',
        '/api/settings',
        '/api/aether/config',
        '/api/workflows/installed',
        '/api/providers',
        '/api/theme',
        '/api/editors',
        '/api/config/analysis',
        '/api/config/verification',
        '/api/config/costs',
        '/api/config/editor',
        '/api/config/mothership',
        '/api/prompts/directories'
    )
    foreach ($ep in $endpoints) {
        $code = 0
        $body = ''
        try {
            $resp = Invoke-WebRequest -Uri "$baseUrl$ep" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $code = [int]$resp.StatusCode
            $body = $resp.Content
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
                $body = $_.Exception.Message
            } else {
                $code = -1
                $body = $_.Exception.Message
            }
        } catch {
            $code = -1
            $body = $_.Exception.Message
        }
        $name = "GET $ep -> 2xx"
        $is2xx = ($code -ge 200 -and $code -lt 300)
        Assert-True -Name $name -Condition $is2xx `
            -Message "Got HTTP $code; body[0..200]=$($body.Substring(0, [Math]::Min(200, $body.Length)))"
    }

    # ─── Server log must be clean of Errors and the canonical regression text ─
    $logFile = Get-ChildItem -Path $logsDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($logFile) {
        $content = Get-Content -LiteralPath $logFile.FullName -Raw
        $errorCount = ([regex]::Matches($content, '"level":"Error"')).Count
        Assert-Equal -Name "Server log has zero level:Error entries" -Expected 0 -Actual $errorCount `
            -Message "Tail: $(($content -split "`n" | Select-Object -Last 10) -join '; ')"
        $routeHits = ([regex]::Matches($content, 'Route handler error')).Count
        Assert-Equal -Name "Server log has zero 'Route handler error' entries" -Expected 0 -Actual $routeHits `
            -Message "Tail: $(($content -split "`n" | Select-Object -Last 10) -join '; ')"
    } else {
        Write-TestResult -Name "Server log produced" -Status Skip -Message "No dotbot-*.jsonl file found in $logsDir"
    }

} finally {
    # Always stop the server and clean up the test project.
    if ($serverProc -and -not $serverProc.HasExited) {
        try { $serverProc.Kill($true) } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message 'Server teardown: Kill failed' -Exception $_
            }
        }
    }
    Remove-TestProject -Path $projectRoot
}

$allPassed = (Write-TestSummary -LayerName "Layer 2: Route Handler Smoke")
if ($allPassed) { exit 0 } else { exit 1 }
