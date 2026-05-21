#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Regression test for the session-id-per-retry fix.
.DESCRIPTION
    The Claude CLI rejects any `--session-id` value that has been used by a
    previous invocation, even after that invocation has exited cleanly. The
    dotbot workflow retry loops generate a fresh GUID on every attempt to
    avoid this. This test guards that contract.

    Drives the unit-level retry behaviour without dotbot's full task-runner.
    A self-contained mock claude shim:
      - On first invocation with a given --session-id: emits a valid
        stream-json envelope to stdout, exits 0.
      - On any subsequent invocation with the same --session-id: emits
        `Error: Session ID <sid> is already in use.` to stderr, exits 1.

    The test invokes Invoke-ClaudeStream three times in succession (mirroring
    the analysis retry budget) and asserts that:
      - Three distinct session IDs were used.
      - No invocation hit the "already in use" path.
      - The seen-IDs file recorded by the mock contains exactly the three
        GUIDs we generated (no reuse).

    Catches a regression where session-id generation is hoisted OUT of the
    retry loop and the same ID is handed to every attempt — exactly the
    issue #25 follow-up reported in the workflow.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Workflow Session-ID Retry Hygiene" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ─── Build the mock claude shim ──────────────────────────────────────────
$mockDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-sid-mock-$(Get-Random)"
New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
$seenIdsFile = Join-Path $mockDir "seen-ids.txt"
'' | Set-Content -Encoding utf8NoBOM -Path $seenIdsFile

# Bash shim: scans args for --session-id, checks against seen-ids.txt, emits
# an Error if reused; otherwise emits a minimal stream-json envelope.
$shim = @"
#!/usr/bin/env bash
sid=''
prev_was_sid=0
for arg in "`$@"; do
    if [ "`$prev_was_sid" = "1" ]; then sid="`$arg"; prev_was_sid=0; continue; fi
    if [ "`$arg" = "--session-id" ]; then prev_was_sid=1; fi
done
if [ -z "`$sid" ]; then
    # No session id provided — fail loudly so the test catches misconfig.
    echo "Mock claude: no --session-id passed" >&2
    exit 2
fi
if grep -Fxq "`$sid" '$seenIdsFile' 2>/dev/null; then
    echo "Error: Session ID `$sid is already in use." >&2
    exit 1
fi
echo "`$sid" >> '$seenIdsFile'
# Drain stdin (prompt is delivered there by dotbot).
cat > /dev/null
# Emit a minimal stream-json envelope so Invoke-ClaudeStream's parser is happy.
printf '{"type":"system","subtype":"init","session_id":"%s"}\n' "`$sid"
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok"}\n'
exit 0
"@
$shimPath = Join-Path $mockDir "claude"
Set-Content -Encoding utf8NoBOM -Path $shimPath -Value $shim
& chmod +x $shimPath 2>$null

# ─── Invoke Invoke-ClaudeStream three times in succession ────────────────
# Mirrors the analysis retry budget (3 attempts: 1 initial + 2 retries).
# Each call generates a fresh GUID via New-ProviderSession.

$repoRoot = Get-RepoRoot
$claudeCliPath = Join-Path $repoRoot "core/runtime/ClaudeCLI/ClaudeCLI.psm1"
$providerCliPath = Join-Path $repoRoot "core/runtime/ProviderCLI/ProviderCLI.psm1"
$themePath = Join-Path $repoRoot "core/runtime/modules/DotBotTheme.psm1"

if (-not (Test-Path $claudeCliPath) -or -not (Test-Path $providerCliPath)) {
    Write-TestResult -Name "Source modules present" -Status Fail -Message "Required PowerShell modules missing"
    Remove-Item $mockDir -Recurse -Force -ErrorAction SilentlyContinue
    [void](Write-TestSummary -LayerName "Layer 1: Workflow Session-ID Retry Hygiene")
    exit 1
}

# Drive three invocations in a fresh pwsh subprocess so PATH override + module
# load are isolated from the test runner. The subprocess writes the captured
# session IDs back to a file we can read here.
$probeScript = @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$env:PATH = '$mockDir' + [System.IO.Path]::PathSeparator + `$env:PATH
`$global:DotbotProjectRoot = '$repoRoot'
Import-Module '$themePath' -Force -DisableNameChecking
Import-Module '$providerCliPath' -Force -DisableNameChecking
Import-Module '$claudeCliPath' -Force -DisableNameChecking

`$ids = @()
for (`$i = 1; `$i -le 3; `$i++) {
    `$sid = New-ProviderSession
    `$ids += `$sid
    try {
        Invoke-ClaudeStream -Prompt "attempt `$i" -Model 'opus' -SessionId `$sid -PersistSession:`$false *>`$null
        Write-Output "OK attempt=`$i sid=`$sid"
    } catch {
        Write-Output "FAIL attempt=`$i sid=`$sid err=`$(`$_.Exception.Message)"
    }
}
"@

$output = & pwsh -NoProfile -Command $probeScript 2>&1
$outputLines = @($output | Where-Object { $_ })

# ─── Assertions ──────────────────────────────────────────────────────────
$okLines = @($outputLines | Where-Object { $_ -match '^OK\s+attempt=' })
$failLines = @($outputLines | Where-Object { $_ -match '^FAIL\s+attempt=' })

Assert-Equal -Name "Three successful Claude invocations (3 attempts × fresh GUID)" `
    -Expected 3 -Actual $okLines.Count `
    -Message "Output:`n$($outputLines -join "`n")"

Assert-Equal -Name "Zero invocations rejected with 'already in use'" `
    -Expected 0 -Actual $failLines.Count `
    -Message "Got: $($failLines -join '; ')"

# Verify the mock saw three distinct session IDs (no reuse).
$seenIds = @(Get-Content -LiteralPath $seenIdsFile -ErrorAction SilentlyContinue | Where-Object { $_ })
Assert-Equal -Name "Mock recorded three distinct session IDs" `
    -Expected 3 -Actual ($seenIds | Sort-Object -Unique).Count `
    -Message "Recorded: $($seenIds -join ', ')"

# Cleanup
Remove-Item $mockDir -Recurse -Force -ErrorAction SilentlyContinue

$allPassed = (Write-TestSummary -LayerName "Layer 1: Workflow Session-ID Retry Hygiene")
if ($allPassed) { exit 0 } else { exit 1 }
