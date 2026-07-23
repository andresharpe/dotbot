# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
param(
    [string]$TaskId,
    [string]$Category
)

# Optional quality gate (#656). Runs the project's configured test/lint
# commands before a task can enter 'done', so failing tests/lint don't
# reach 'done' (and a PR) on the framework's word alone. Disabled by
# default via quality_gate.enabled in settings.default.json — a project
# opts in by setting quality_gate.enabled + test_command/lint_command in
# its own settings override (e.g. .bot/.control/settings.json).

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Write-QualityResult {
    param(
        [Parameter(Mandatory)][bool]$Success,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Details = @{},
        [array]$Failures = @()
    )
    @{
        success  = $Success
        script   = "05-verify-quality.ps1"
        message  = $Message
        details  = $Details
        failures = $Failures
    } | ConvertTo-Json -Depth 10
}

function Resolve-DotbotModulePath {
    param([Parameter(Mandatory)][string]$ModuleName)

    $frameworkRoot = Join-Path $PSScriptRoot ".." ".."
    $found = Resolve-FirstExistingPath @(
        (Join-Path $frameworkRoot "runtime" "Modules" $ModuleName "$ModuleName.psm1"),
        (Join-Path $frameworkRoot "src" "runtime" "Modules" $ModuleName "$ModuleName.psm1")
    )
    if ($found) { return $found }

    $root = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($root) {
        return Resolve-FirstExistingPath @(
            (Join-Path $root ".bot" "src" "runtime" "Modules" $ModuleName "$ModuleName.psm1"),
            (Join-Path $root "src" "runtime" "Modules" $ModuleName "$ModuleName.psm1")
        )
    }
    return $null
}

# Dotbot.Settings depends on Dotbot.Core (Get-DotbotInstallPath,
# Get-DotbotUserSettingsPath) being importable in the same session.
$corePath = Resolve-DotbotModulePath -ModuleName "Dotbot.Core"
if ($corePath) { Import-Module $corePath -Force -DisableNameChecking }

$settingsModulePath = Resolve-DotbotModulePath -ModuleName "Dotbot.Settings"
if (-not $settingsModulePath) {
    Write-QualityResult -Success $true -Message "Quality gate settings module not found; skipped." -Details @{ enabled = $false }
    exit 0
}
Import-Module $settingsModulePath -Force -DisableNameChecking

$botRoot = Join-Path (Get-Location).Path ".bot"
$settings = Get-MergedSettings -BotRoot $botRoot
$gate = $settings.quality_gate

if (-not $gate -or -not [bool]$gate.enabled) {
    Write-QualityResult -Success $true -Message "Quality gate not enabled; skipped." -Details @{ enabled = $false }
    exit 0
}

$checks = @()
if (-not [string]::IsNullOrWhiteSpace([string]$gate.test_command)) {
    $checks += @{ name = "test"; command = [string]$gate.test_command }
}
if (-not [string]::IsNullOrWhiteSpace([string]$gate.lint_command)) {
    $checks += @{ name = "lint"; command = [string]$gate.lint_command }
}

if ($checks.Count -eq 0) {
    Write-QualityResult -Success $true `
        -Message "Quality gate enabled but no test_command/lint_command configured; skipped." `
        -Details @{ enabled = $true }
    exit 0
}

$failures = @()
$ranChecks = @()
foreach ($check in $checks) {
    $output = $null
    $exitCode = $null
    try {
        # Run in a child pwsh rather than Invoke-Expression in-process: the
        # command string is project-supplied config (same trust level as a
        # CI yaml step), and a child process keeps it from touching this
        # runspace's variables/functions.
        $output = & pwsh -NoProfile -Command "$($check.command) 2>&1" | Out-String
        $exitCode = $LASTEXITCODE
    } catch {
        $output = $_.Exception.Message
        $exitCode = 1
    }
    $ranChecks += @{ name = $check.name; command = $check.command; exit_code = $exitCode }
    if ($exitCode -ne 0) {
        $tail = if ($output) { (($output -split "`r?`n" | Select-Object -Last 40) -join "`n") } else { "" }
        $failures += @{
            issue    = "$($check.name) command failed (exit $exitCode): $($check.command)"
            severity = "error"
            context  = $tail
        }
    }
}

Write-QualityResult -Success ($failures.Count -eq 0) `
    -Message $(if ($failures.Count -eq 0) { "Quality gate passed ($($ranChecks.Count) check(s))" } else { "Quality gate failed" }) `
    -Details @{ enabled = $true; checks = $ranChecks } `
    -Failures $failures

# Signal failure via the JSON 'success' field only, not the process exit
# code — the last check command's own nonzero exit would otherwise leak
# through as this script's exit code and short-circuit enter-done's JSON
# parsing (it treats a nonzero exit code as a harder, pre-JSON failure).
exit 0
