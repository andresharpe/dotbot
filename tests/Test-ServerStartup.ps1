#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: UI server startup sequence tests.
.DESCRIPTION
    Tests that multiple dotbot UI servers for different projects start on
    separate ports and that /api/info returns the correct project_root,
    which go.ps1 relies on to distinguish between projects.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: UI Server Startup Sequence Tests" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Server Startup"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════

function Start-UiServer {
    <#
    .SYNOPSIS
        Start a dotbot UI server as a background process (no window, no browser).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir
    )

    $serverScript = Join-Path $BotDir "core/ui/server.ps1"
    if (-not (Test-Path $serverScript)) {
        throw "UI server script not found: $serverScript"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`""
    $psi.WorkingDirectory = Split-Path -Parent $BotDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    # Drain stdout/stderr asynchronously to prevent pipe buffer deadlock
    # (the server produces Write-Host output that fills the OS pipe buffer)
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    return $process
}

function Wait-ForUiPort {
    <#
    .SYNOPSIS
        Poll for the ui-port file and return the port number.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir,
        [int]$TimeoutSeconds = 15
    )

    $portFile = Join-Path $BotDir ".control\ui-port"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path $portFile) {
            $content = Get-Content $portFile -Raw
            if ($null -ne $content) {
                $raw = $content.Trim()
                if ($raw -match '^\d+$') {
                    return [int]$raw
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}

function Wait-ForServerReady {
    <#
    .SYNOPSIS
        Wait until the server is actually accepting HTTP connections on the given port.
        The port file may be written before the HttpListener is ready (observed on macOS).
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$Port/api/info" -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                return ($resp.Content | ConvertFrom-Json)
            }
        } catch {
            Write-Verbose "Server not ready yet — keep polling: $_"
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Stop-UiServer {
    param(
        [System.Diagnostics.Process]$Process
    )
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { Write-Verbose "Non-critical operation failed: $_" }
        try { [void]$Process.WaitForExit(3000) } catch { Write-Verbose "Cleanup: failed to stop process: $_" }
    }
    try { $Process.Dispose() } catch { Write-Verbose "Cleanup: failed to stop process: $_" }
}

function Initialize-TestBotProject {
    <#
    .SYNOPSIS
        Create a temp project from the default golden .bot/ snapshot.
    .DESCRIPTION
        Local override that delegates to New-TestProjectFromGolden so each
        Test-ServerStartup section gets a ready .bot/ in ~1-3s instead of
        paying the 30s init cost. The HTTP server tests don't depend on
        having a freshly-initialised .bot/, only a clean one.
    #>
    return New-TestProjectFromGolden -Flavor 'default'
}

# ═══════════════════════════════════════════════════════════════════
# MULTI-INSTANCE SERVER TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MULTI-INSTANCE SERVER STARTUP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$projectA = $null
$projectB = $null
$serverA = $null
$serverB = $null

try {
    # Set up two independent projects
    $projectA = Initialize-TestBotProject
    $projectB = Initialize-TestBotProject

    # Start Project A's server
    $serverA = Start-UiServer -BotDir $projectA.BotDir
    $portA = Wait-ForUiPort -BotDir $projectA.BotDir

    Assert-True -Name "Project A server starts and writes port" `
        -Condition ($portA -gt 0) `
        -Message "Failed to detect port from ui-port file"

    if ($portA -gt 0) {
        # Wait for server A to be fully ready (port file can appear before HttpListener binds)
        $infoA = Wait-ForServerReady -Port $portA

        Assert-True -Name "Project A /api/info responds" `
            -Condition ($null -ne $infoA) `
            -Message "No response from /api/info after waiting for server readiness"

        if ($infoA) {
            Assert-Equal -Name "Project A /api/info returns correct project_root" `
                -Expected $projectA.ProjectRoot `
                -Actual $infoA.project_root
        }

        # Simulate the conflict: write Project A's port into Project B's ui-port file
        $portA.ToString() | Set-Content (Join-Path $projectB.ControlDir "ui-port") -NoNewline -Encoding UTF8

        # Verify that /api/info on the conflicting port returns Project A's root (not B's)
        $infoConflict = $null
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$portA/api/info" -TimeoutSec 2 -ErrorAction Stop
            $infoConflict = $resp.Content | ConvertFrom-Json
        } catch { Write-Verbose "Failed to parse data: $_" }

        if ($infoConflict) {
            Assert-True -Name "Conflicting port /api/info returns different project_root" `
                -Condition ($infoConflict.project_root -ne $projectB.ProjectRoot) `
                -Message "Server on port $portA should belong to Project A, not Project B"
        }

        # Remove the conflicting ui-port file before starting server B
        # (just like go.ps1 line 89 does before launching a new server)
        $conflictPortFile = Join-Path $projectB.ControlDir "ui-port"
        if (Test-Path $conflictPortFile) { Remove-Item $conflictPortFile -Force }

        # Start Project B's server — it should auto-select a different port
        $serverB = Start-UiServer -BotDir $projectB.BotDir
        $portB = Wait-ForUiPort -BotDir $projectB.BotDir

        Assert-True -Name "Project B server starts and writes port" `
            -Condition ($portB -gt 0) `
            -Message "Failed to detect port from ui-port file"

        Assert-True -Name "Project B gets a different port than Project A" `
            -Condition ($portB -ne $portA) `
            -Message "Project B got port $portB, same as Project A ($portA)"

        if ($portB -gt 0 -and $portB -ne $portA) {
            # Wait for server B to be fully ready
            $infoB = Wait-ForServerReady -Port $portB

            Assert-True -Name "Project B /api/info responds" `
                -Condition ($null -ne $infoB) `
                -Message "No response from /api/info on port $portB"

            if ($infoB) {
                Assert-Equal -Name "Project B /api/info returns correct project_root" `
                    -Expected $projectB.ProjectRoot `
                    -Actual $infoB.project_root
            }
        }
    }

} catch {
    Write-TestResult -Name "Multi-instance server tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    Stop-UiServer -Process $serverB
    Stop-UiServer -Process $serverA
    if ($projectB) { Remove-TestProject -Path $projectB.ProjectRoot }
    if ($projectA) { Remove-TestProject -Path $projectA.ProjectRoot }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PER-WORKFLOW FORM ENDPOINT (issue #235)
# ═══════════════════════════════════════════════════════════════════
# Regression coverage: when multiple workflows are installed in
# .bot/workflows/, GET /api/workflows/{name}/form must return the form
# config for the requested workflow — not the alphabetically-first one.

Write-Host "  PER-WORKFLOW FORM ENDPOINT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$projectForm = $null
$serverForm = $null

try {
    $projectForm = Initialize-TestBotProject

    # Install two workflows with distinct form blocks directly on disk.
    # Use alphabetically reversed order (alpha first) so the test would
    # fail if the endpoint ever reverted to "return first workflow found".
    $workflowsRoot = Join-Path $projectForm.BotDir "workflows"
    New-Item -Path (Join-Path $workflowsRoot "alpha") -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $workflowsRoot "bravo") -ItemType Directory -Force | Out-Null

    $alphaYaml = @"
name: alpha
version: "1.0"
description: Alpha test workflow
form:
  description: "ALPHA WORKFLOW FORM"
  prompt_placeholder: "ALPHA project description..."
  interview_label: "ALPHA interview"
  interview_hint: "Alpha hint"
  show_prompt: true
  show_files: true
  show_interview: true
tasks:
  - name: "Alpha Phase 1"
    type: prompt
    workflow: "alpha-1.md"
"@

    $bravoYaml = @"
name: bravo
version: "1.0"
description: Bravo test workflow
form:
  description: "BRAVO WORKFLOW FORM"
  prompt_placeholder: "BRAVO project description..."
  interview_label: "BRAVO interview"
  interview_hint: "Bravo hint"
  show_prompt: true
  show_files: false
  show_interview: true
  show_auto_workflow: false
tasks:
  - name: "Bravo Phase 1"
    type: prompt
    workflow: "bravo-1.md"
  - name: "Bravo Phase 2"
    type: prompt
    workflow: "bravo-2.md"
"@

    Set-Content -Path (Join-Path $workflowsRoot "alpha\workflow.yaml") -Value $alphaYaml -Encoding UTF8
    Set-Content -Path (Join-Path $workflowsRoot "bravo\workflow.yaml") -Value $bravoYaml -Encoding UTF8

    $serverForm = Start-UiServer -BotDir $projectForm.BotDir
    $portForm = Wait-ForUiPort -BotDir $projectForm.BotDir

    Assert-True -Name "Form-endpoint server starts" `
        -Condition ($portForm -gt 0) `
        -Message "Failed to detect port from ui-port file"

    if ($portForm -gt 0) {
        [void](Wait-ForServerReady -Port $portForm)

        # --- Fetch alpha form ---
        $alphaResp = $null
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$portForm/api/workflows/alpha/form" -TimeoutSec 5 -ErrorAction Stop
            $alphaResp = $r.Content | ConvertFrom-Json
        } catch { Write-Verbose "alpha form fetch failed: $_" }

        Assert-True -Name "GET /api/workflows/alpha/form returns success" `
            -Condition ($null -ne $alphaResp -and $alphaResp.success -eq $true) `
            -Message "Expected success=true, got: $($alphaResp | ConvertTo-Json -Compress -Depth 4)"

        if ($alphaResp -and $alphaResp.success) {
            Assert-Equal -Name "alpha form.description matches alpha manifest" `
                -Expected "ALPHA WORKFLOW FORM" `
                -Actual $alphaResp.dialog.description
            Assert-Equal -Name "alpha form.prompt_placeholder matches alpha manifest" `
                -Expected "ALPHA project description..." `
                -Actual $alphaResp.dialog.prompt_placeholder
            Assert-Equal -Name "alpha phases count matches alpha manifest" `
                -Expected 1 `
                -Actual ([int]$alphaResp.phases.Count)
        }

        # --- Fetch bravo form — this is the core regression check ---
        $bravoResp = $null
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$portForm/api/workflows/bravo/form" -TimeoutSec 5 -ErrorAction Stop
            $bravoResp = $r.Content | ConvertFrom-Json
        } catch { Write-Verbose "bravo form fetch failed: $_" }

        Assert-True -Name "GET /api/workflows/bravo/form returns success" `
            -Condition ($null -ne $bravoResp -and $bravoResp.success -eq $true) `
            -Message "Expected success=true, got: $($bravoResp | ConvertTo-Json -Compress -Depth 4)"

        if ($bravoResp -and $bravoResp.success) {
            Assert-Equal -Name "bravo form.description matches bravo manifest (not alpha)" `
                -Expected "BRAVO WORKFLOW FORM" `
                -Actual $bravoResp.dialog.description
            Assert-Equal -Name "bravo form.prompt_placeholder matches bravo manifest (not alpha)" `
                -Expected "BRAVO project description..." `
                -Actual $bravoResp.dialog.prompt_placeholder
            Assert-Equal -Name "bravo form.show_files respects bravo manifest" `
                -Expected $false `
                -Actual ([bool]$bravoResp.dialog.show_files)
            Assert-Equal -Name "bravo form.show_auto_workflow respects bravo manifest" `
                -Expected $false `
                -Actual ([bool]$bravoResp.dialog.show_auto_workflow)
            Assert-Equal -Name "alpha form.show_auto_workflow defaults to true" `
                -Expected $true `
                -Actual ([bool]$alphaResp.dialog.show_auto_workflow)
            Assert-Equal -Name "bravo phases count matches bravo manifest" `
                -Expected 2 `
                -Actual ([int]$bravoResp.phases.Count)
        }

        # --- 404 for unknown workflow ---
        $unknownStatus = 0
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$portForm/api/workflows/does-not-exist/form" -TimeoutSec 5 -ErrorAction Stop
            $unknownStatus = [int]$r.StatusCode
        } catch {
            $unknownStatus = [int]$_.Exception.Response.StatusCode
        }
        Assert-Equal -Name "Unknown workflow returns 404" -Expected 404 -Actual $unknownStatus

        # --- 400 for invalid workflow name (path traversal guard) ---
        $traversalStatus = 0
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$portForm/api/workflows/..%2Fetc/form" -TimeoutSec 5 -ErrorAction Stop
            $traversalStatus = [int]$r.StatusCode
        } catch {
            $traversalStatus = [int]$_.Exception.Response.StatusCode
        }
        Assert-True -Name "Path-traversal workflow name is rejected (400 or 404)" `
            -Condition ($traversalStatus -eq 400 -or $traversalStatus -eq 404) `
            -Message "Expected 400/404, got $traversalStatus"
    }

} catch {
    Write-TestResult -Name "Per-workflow form endpoint tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    Stop-UiServer -Process $serverForm
    if ($projectForm) { Remove-TestProject -Path $projectForm.ProjectRoot }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# BOOTSTRAP INJECTION (issue #269)
# ═══════════════════════════════════════════════════════════════════
# Validates that the `/` route inlines window.__DOTBOT_BOOTSTRAP__ data into
# index.html so first paint has project info without a /api/info round-trip,
# that /api/info's shape is preserved after the Get-ProjectInfoPayload refactor,
# and that ConvertTo-InlineScriptJson escapes `</` as `<\/` so manifest content
# containing `</script>` cannot prematurely close the data island.

Write-Host "  BOOTSTRAP INJECTION (issue #269)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$projectBoot = $null
$serverBoot = $null

try {
    $projectBoot = Initialize-TestBotProject

    # Plant a product doc with an executive summary containing all three case
    # variants of `</script>`. This is the only content path that reaches the
    # bootstrap payload (via info.executive_summary), so it's where the
    # ConvertTo-InlineScriptJson escape is exercised end-to-end. HTML5
    # script-tag termination is case-insensitive, so we assert that all of
    # `</script>`, `</SCRIPT>`, `</Script>` are escaped in the data island.
    $productDir = Join-Path $projectBoot.BotDir "workspace\product"
    New-Item -Path $productDir -ItemType Directory -Force | Out-Null
    $overviewMd = @"
# Overview

## Executive Summary

Test project with a script tag </script> lower </SCRIPT> upper </Script> mixed end.
"@
    Set-Content -Path (Join-Path $productDir "overview.md") -Value $overviewMd -Encoding UTF8

    $serverBoot = Start-UiServer -BotDir $projectBoot.BotDir
    $portBoot = Wait-ForUiPort -BotDir $projectBoot.BotDir

    Assert-True -Name "Bootstrap-injection server starts" `
        -Condition ($portBoot -gt 0) `
        -Message "Failed to detect port from ui-port file"

    if ($portBoot -gt 0) {
        [void](Wait-ForServerReady -Port $portBoot)

        # --- GET / returns HTML containing a non-empty data island ---
        $indexHtml = $null
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$portBoot/" -TimeoutSec 5 -ErrorAction Stop
            $indexHtml = $r.Content
        } catch { Write-Verbose "GET / failed: $_" }

        Assert-True -Name "GET / returns HTML" `
            -Condition ($null -ne $indexHtml -and $indexHtml.Length -gt 100) `
            -Message "No HTML returned from /"

        if ($indexHtml) {
            $islandMatch = [regex]::Match($indexHtml, '<script id="__dotbot_bootstrap_data" type="application/json">([\s\S]*?)</script>')
            Assert-True -Name "GET / includes bootstrap data island" `
                -Condition $islandMatch.Success `
                -Message "Could not find <script id=__dotbot_bootstrap_data> tag in response"

            if ($islandMatch.Success) {
                $islandContent = $islandMatch.Groups[1].Value.Trim()

                Assert-True -Name "Data island is non-empty and has substituted JSON" `
                    -Condition ($islandContent.Length -gt 0 -and -not $islandContent.StartsWith('{{')) `
                    -Message "Data island empty or still carries unsubstituted {{BOOTSTRAP_JSON}} placeholder"

                # Parseability — the client does JSON.parse on this text.
                $bootstrap = $null
                try { $bootstrap = $islandContent | ConvertFrom-Json } catch { Write-Verbose "ConvertFrom-Json failed: $_" }

                Assert-True -Name "Data island content is valid JSON" `
                    -Condition ($null -ne $bootstrap) `
                    -Message "JSON parse failed on island content"

                if ($bootstrap) {
                    Assert-True -Name "Bootstrap.info exists" `
                        -Condition ($null -ne $bootstrap.info) `
                        -Message "info missing from bootstrap payload"
                    Assert-True -Name "Bootstrap.productList exists" `
                        -Condition ($null -ne $bootstrap.productList) `
                        -Message "productList missing from bootstrap payload"

                    if ($bootstrap.info) {
                        Assert-Equal -Name "Bootstrap.info.project_name == project leaf" `
                            -Expected (Split-Path -Leaf $projectBoot.ProjectRoot) `
                            -Actual $bootstrap.info.project_name
                        Assert-True -Name "Bootstrap.info.executive_summary captures overview.md content" `
                            -Condition ($null -ne $bootstrap.info.executive_summary -and $bootstrap.info.executive_summary -like "Test project with a script tag*") `
                            -Message "Got: $($bootstrap.info.executive_summary)"
                        # Confirm the raw source really carried all three case
                        # variants before escape — otherwise the escape test
                        # below could silently pass on missing content.
                        Assert-True -Name "overview.md seeded with all three </script> case variants" `
                            -Condition ($bootstrap.info.executive_summary -cmatch 'lower' -and `
                                        $bootstrap.info.executive_summary -cmatch 'upper' -and `
                                        $bootstrap.info.executive_summary -cmatch 'mixed') `
                            -Message "Planted executive_summary markers missing"
                    }
                    if ($bootstrap.productList) {
                        $overviewCount = @($bootstrap.productList.docs | Where-Object { $_.filename -like "*overview*" -or $_.name -like "*overview*" }).Count
                        Assert-True -Name "Bootstrap.productList.docs lists overview.md" `
                            -Condition ($overviewCount -gt 0) `
                            -Message "overview.md not found in productList.docs"
                    }
                }

                # Security-relevant invariant: the escape must turn "</" into "<\/"
                # inside the data island. Without it, "</script>" inside the
                # executive summary would prematurely close the script tag and
                # leak content into the body.
                #
                # HTML5 script-tag termination is case-insensitive, but the
                # `</` -> `<\/` replacement in ConvertTo-InlineScriptJson
                # targets non-letter characters (`<` and `/`), so the case of
                # the trailing `script` word is irrelevant — all variants are
                # escaped by the same replacement. We verify that explicitly
                # with -cmatch / -cnotmatch (case-sensitive) for each variant
                # the overview.md planted above.
                $variantChecks = @(
                    @{ Literal = '</script'; Escaped = '<\/script' },
                    @{ Literal = '</SCRIPT'; Escaped = '<\/SCRIPT' },
                    @{ Literal = '</Script'; Escaped = '<\/Script' }
                )
                foreach ($v in $variantChecks) {
                    Assert-True -Name "Data island has no literal '$($v.Literal)'" `
                        -Condition ($islandContent -cnotmatch [regex]::Escape($v.Literal)) `
                        -Message "Expected '$($v.Literal)' to be escaped, found literal occurrence"
                    Assert-True -Name "Data island contains escaped '$($v.Escaped)'" `
                        -Condition ($islandContent -cmatch [regex]::Escape($v.Escaped)) `
                        -Message "Expected escaped '$($v.Escaped)' in data island"
                }
            }
        }

        # --- /api/info shape regression after Get-ProjectInfoPayload refactor ---
        $infoResp = $null
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$portBoot/api/info" -TimeoutSec 5 -ErrorAction Stop
            $infoResp = $r.Content | ConvertFrom-Json
        } catch { Write-Verbose "/api/info fetch failed: $_" }

        Assert-True -Name "/api/info still responds after refactor" `
            -Condition ($null -ne $infoResp) `
            -Message "No response from /api/info"

        if ($infoResp) {
            foreach ($key in @('project_name', 'project_root', 'full_path', 'executive_summary', 'workflow', 'kickstart_dialog', 'kickstart_phases', 'kickstart_mode', 'installed_workflows')) {
                Assert-True -Name "/api/info exposes '$key' after refactor" `
                    -Condition ($infoResp.PSObject.Properties.Name -contains $key) `
                    -Message "Expected '$key' in /api/info response"
            }
        }
    }

} catch {
    Write-TestResult -Name "Bootstrap injection tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    Stop-UiServer -Process $serverBoot
    if ($projectBoot) { Remove-TestProject -Path $projectBoot.ProjectRoot }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Server Startup"

if (-not $allPassed) {
    exit 1
}
