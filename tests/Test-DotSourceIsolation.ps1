#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Enforce that .ps1 files dot-sourced from other scopes do not
    leak `Set-StrictMode -Version 3.0` (or any other top-level state change)
    into the caller.
.DESCRIPTION
    Would have caught the issue-#25 regression where the directive sweep
    placed `Set-StrictMode -Version 3.0` at file top in scripts that are
    dot-sourced from `core/ui/modules/StateBuilder.psm1` (Get-BotState ->
    session-get-state/script.ps1). That leaked strict mode into Get-BotState
    and surfaced as `Route handler error: The property 'workflow' cannot be
    found on this object` from /api/state.

    Two checks:
      1. Runtime probe (definitive): for each dot-source target, spawn a
         fresh pwsh subprocess with Set-StrictMode -Off, dot-source the file,
         then probe a missing property on a PSCustomObject. If the probe
         throws, the file elevated strict mode (or otherwise polluted the
         caller's scope).
      2. Static lint (fast): AST-parse each dot-source target, fail if
         `Set-StrictMode` appears at script-block top level. Strict mode
         belongs inside function bodies in dot-sourceable files.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Dot-Source Isolation (issue #25 regression guard)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ─── Discover dot-source targets ─────────────────────────────────────────
# Find every line that dot-sources another .ps1 in the repo. We capture both
# `. ./path.ps1` and `. "$PSScriptRoot/..."` style invocations.
Push-Location $repoRoot
$dotSourceLines = & git grep -nE "^[[:space:]]*\.[[:space:]]+['\""]?[^|<>;'\""]*\.ps1" -- '*.ps1' '*.psm1' 2>$null
Pop-Location

if (-not $dotSourceLines) {
    Write-TestResult -Name "Discover dot-source targets" -Status Fail -Message "git grep returned no matches"
    [void](Write-TestSummary -LayerName "Layer 1: Dot-Source Isolation")
    exit 1
}

# Parse "file:line:content" → extract the RHS .ps1 path and resolve to an absolute path.
$targets = New-Object System.Collections.Generic.HashSet[string]
foreach ($line in $dotSourceLines) {
    if ($line -notmatch '^([^:]+):\d+:\s*\.\s+(.+)$') { continue }
    $sourceFile = $Matches[1]
    $rhsExpr = $Matches[2].Trim()

    # Strip surrounding parens / quotes.
    $rhsExpr = $rhsExpr -replace '^\(\s*', '' -replace '\s*\)\s*$', ''
    $rhsExpr = $rhsExpr -replace '^["'']', '' -replace '["'']$', ''

    # Skip Join-Path forms — too dynamic to resolve statically.
    if ($rhsExpr -match '^Join-Path\b') { continue }

    # Substitute the variables we know how to resolve statically. $BotRoot is
    # a function-local that always points at <project>/.bot or <repo>; treat
    # it as the repo root for discovery purposes.
    $sourceDir = Split-Path -Parent (Join-Path $repoRoot $sourceFile)
    $resolved = $rhsExpr -replace '\$PSScriptRoot', $sourceDir
    $resolved = $resolved -replace '\$global:DotbotProjectRoot', $repoRoot
    $resolved = $resolved -replace '\$BotRoot', $repoRoot
    $resolved = $resolved -replace '\$botRoot', $repoRoot
    $resolved = $resolved -replace '\\', '/'

    # Drop anything still containing a variable — we can't resolve it.
    if ($resolved -match '\$') { continue }

    # Normalise via realpath when possible.
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $sourceDir $resolved
    }
    try {
        $resolved = [System.IO.Path]::GetFullPath($resolved)
    } catch {
        continue
    }

    if (Test-Path -LiteralPath $resolved) {
        [void]$targets.Add($resolved)
    }
}

Write-Host "  Discovered $($targets.Count) unique dot-source target(s)" -ForegroundColor DarkGray
Write-Host ""

if ($targets.Count -eq 0) {
    Write-TestResult -Name "Dot-source target discovery" -Status Fail -Message "No targets resolved from git grep output"
    [void](Write-TestSummary -LayerName "Layer 1: Dot-Source Isolation")
    exit 1
}

# ─── Static lint: no top-level Set-StrictMode in dot-source targets ──────
Write-Host "  STATIC LINT — Set-StrictMode placement" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$lintViolations = New-Object System.Collections.Generic.List[string]
foreach ($target in $targets) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        # Parse errors are reported by Test-Compilation.ps1, skip here.
        continue
    }

    # Look for Set-StrictMode commands at script-block top level (not inside any function).
    $topLevelCommands = $ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.PipelineAst]
    }
    foreach ($pipe in $topLevelCommands) {
        $cmd = $pipe.PipelineElements[0]
        if ($cmd -isnot [System.Management.Automation.Language.CommandAst]) { continue }
        $name = $cmd.CommandElements[0].Value
        if ($name -eq 'Set-StrictMode') {
            $rel = $target.Substring($repoRoot.Length + 1).Replace('\', '/')
            $lintViolations.Add("$rel`:$($cmd.Extent.StartLineNumber)  $($cmd.Extent.Text)")
        }
    }
}

if ($lintViolations.Count -eq 0) {
    Write-TestResult -Name "No top-level Set-StrictMode in dot-source targets" -Status Pass
} else {
    $sample = ($lintViolations | Select-Object -First 20) -join "`n    "
    $extra = if ($lintViolations.Count -gt 20) { "`n    ... and $($lintViolations.Count - 20) more" } else { "" }
    Write-TestResult -Name "No top-level Set-StrictMode in dot-source targets" -Status Fail `
        -Message "Found $($lintViolations.Count) leak vector(s). Move Set-StrictMode inside the function body so dot-sourcing does not pollute the caller:`n    $sample$extra"
}

Write-Host ""

# ─── Runtime probe: dot-source each target, verify strict mode untouched ─
Write-Host "  RUNTIME PROBE — fresh subprocess per target" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$leaks = New-Object System.Collections.Generic.List[string]
foreach ($target in $targets) {
    $rel = $target.Substring($repoRoot.Length + 1).Replace('\', '/')

    # Build a probe script:
    #   - Disable strict mode in the parent scope
    #   - Dot-source the target. If it has executable code that requires
    #     environmental state (e.g. $global:DotbotProjectRoot), that may
    #     fail — we tolerate that by capturing errors and only flagging
    #     the specific "missing property" leak.
    #   - Read a missing property on a PSCustomObject. Under strict 3.0
    #     this throws; under any lower mode it returns $null.
    $probe = @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$global:DotbotProjectRoot = '$repoRoot'
try { . '$($target -replace "'", "''")' } catch { }
try {
    `$x = [pscustomobject]@{ a = 1 }
    `$null = `$x.b
    Write-Output 'OK'
} catch [System.Management.Automation.PropertyNotFoundException] {
    Write-Output "LEAK: `$(`$_.Exception.Message)"
} catch {
    Write-Output "LEAK: `$(`$_.Exception.Message)"
}
"@

    $output = & pwsh -NoProfile -Command $probe 2>$null
    $lastLine = ($output | Where-Object { $_ } | Select-Object -Last 1)
    if ($lastLine -notmatch '^OK$') {
        $leaks.Add("$rel  --  $lastLine")
    }
}

if ($leaks.Count -eq 0) {
    Write-TestResult -Name "Dot-sourcing each target does not elevate strict mode in caller" -Status Pass `
        -Message "Probed $($targets.Count) target(s); none leaked."
} else {
    $sample = ($leaks | Select-Object -First 20) -join "`n    "
    $extra = if ($leaks.Count -gt 20) { "`n    ... and $($leaks.Count - 20) more" } else { "" }
    Write-TestResult -Name "Dot-sourcing each target does not elevate strict mode in caller" -Status Fail `
        -Message "Found $($leaks.Count) leak(s). The file changes the caller's strict mode (or other top-level state); move directives inside function bodies:`n    $sample$extra"
}

$allPassed = (Write-TestSummary -LayerName "Layer 1: Dot-Source Isolation")
if ($allPassed) { exit 0 } else { exit 1 }
