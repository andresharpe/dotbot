#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Dependency resolution across Windows PATH scopes (Machine/User registry vs process).
.DESCRIPTION
    Reproduces the split-PATH bug: on Windows, Machine PATH and User PATH are
    merged at login, but a dotbot child process can inherit a process PATH that
    is missing one scope (e.g. Git installed system-wide -> Machine PATH,
    Claude installed per-user -> User PATH). Detection via Get-Command then
    reports the tools MISSING even though they are registered on the machine.

    These tests encode the FIXED behavior and fail until the fix lands:
      - Test-Preflight must resolve git/claude via the registry Machine/User
        PATH when the process PATH lacks them (issue checkbox 1).
      - The failure/detection output must name the tool and the PATH scope it
        was found in (issue checkbox 2, asserted loosely).
      - 'dotbot doctor' must detect the split instead of reporting
        "not found on PATH" (issue checkbox 3).
      - 'dotbot doctor' must propagate doctor.ps1's exit code through
        bin/dotbot.ps1 (secondary bug: the dispatcher swallows it).

    The split is simulated per-process only: child pwsh processes are spawned
    with the tool directories filtered out of $env:PATH. The registry
    Machine/User PATH is read-only here and NEVER modified.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: Dependency PATH Resolution Tests" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ===================================================================
# GUARDS
# ===================================================================

if (-not $IsWindows) {
    Write-TestResult -Name "Dependency PATH resolution" -Status Skip -Message "Windows-only (registry Machine/User PATH scopes)"
    Write-TestSummary -LayerName "Layer 2: Dependency PATH Resolution"
    exit 0
}

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally - set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 2: Dependency PATH Resolution"
    exit 1
}

# ===================================================================
# HELPERS (file-private; only $env:PATH is ever modified, with restore)
# ===================================================================

$script:PwshExe = (Get-Command pwsh).Source
$script:ProbeExtensions = @('exe', 'cmd', 'bat', 'ps1')

function Get-RegistryPathDirectories {
    param([Parameter(Mandatory)][ValidateSet('Machine', 'User')][string[]]$Scope)
    $dirs = foreach ($s in $Scope) {
        ([Environment]::GetEnvironmentVariable('Path', $s) -split ';') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    return @($dirs)
}

function Find-CommandInDirectories {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Directories
    )
    foreach ($d in @($Directories)) {
        foreach ($ext in $script:ProbeExtensions) {
            try {
                $candidate = Join-Path $d "$Name.$ext"
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            } catch { }   # malformed PATH entries throw on Join-Path/Test-Path
        }
    }
    return $null
}

function Get-ProcessPathWithoutCommands {
    # Drops every process-PATH entry that ships one of the given commands,
    # simulating a child process that did not inherit those PATH segments.
    param([Parameter(Mandatory)][string[]]$Commands)
    $kept = foreach ($entry in ($env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $ships = $false
        foreach ($cmd in $Commands) {
            if (Find-CommandInDirectories -Name $cmd -Directories @($entry)) { $ships = $true; break }
        }
        if (-not $ships) { $entry }
    }
    return ($kept -join ';')
}

function Invoke-ChildPwsh {
    # Runs pwsh with a controlled process PATH; restores the caller's PATH.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $old = $env:PATH
    $env:PATH = $Path
    try {
        $output = & $script:PwshExe -NoProfile -NonInteractive @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $old
    }
    return @{ Output = @($output | ForEach-Object { "$_" }); ExitCode = $code }
}

function Test-AnyLineNamesToolAndScope {
    # Issue checkbox 2, asserted loosely: some single line must name the tool
    # AND a PATH scope (Machine/User). Per-line matching keeps path noise like
    # C:\Users\... in other lines from green-lighting the assertion.
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$Lines
    )
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        if ($line -match "(?i)$Tool" -and $line -match '(?i)\b(machine|user)\b') { return $true }
    }
    return $false
}

# Registry PATH preconditions (read-only probes)
$registryDirs = Get-RegistryPathDirectories -Scope @('Machine', 'User')
$gitInRegistry = Find-CommandInDirectories -Name 'git' -Directories $registryDirs
if (-not $gitInRegistry) {
    Write-TestResult -Name "Dependency PATH resolution" -Status Skip -Message "git not found in registry Machine/User PATH on this machine"
    Write-TestSummary -LayerName "Layer 2: Dependency PATH Resolution"
    exit 0
}

$userRegistryDirs = Get-RegistryPathDirectories -Scope @('User')
$claudeInUserRegistry = Find-CommandInDirectories -Name 'claude' -Directories $userRegistryDirs

# Dotbot.Core provides ConvertTo-SanitizedConsoleText (doctor output has ANSI escapes)
Import-Module (Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Core/Dotbot.Core.psd1") -Force -DisableNameChecking

# ===================================================================
# SETUP: temp project fixture (bare .bot is enough for Test-Preflight
# to resolve the framework-tier claude provider config via DOTBOT_HOME)
# ===================================================================

$proj = New-TestProject -Prefix "dotbot-test-pathres"
$botRoot = Join-Path $proj ".bot"
New-Item -ItemType Directory -Path $botRoot -Force | Out-Null

# Child script: reports what Get-Command sees, runs Test-Preflight, writes JSON
$childScript = Join-Path $proj "run-preflight.ps1"
@'
param(
    [Parameter(Mandatory)][string]$DotbotHome,
    [Parameter(Mandatory)][string]$BotRoot,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $WorkDir
"SANITY-GIT: $([bool](Get-Command git -ErrorAction SilentlyContinue))"
"SANITY-CLAUDE: $([bool](Get-Command claude -ErrorAction SilentlyContinue))"
$modules = Join-Path $DotbotHome 'src/runtime/Modules'
Import-Module (Join-Path $modules 'Dotbot.Core/Dotbot.Core.psd1')         -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Dotbot.Settings/Dotbot.Settings.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Dotbot.Logging/Dotbot.Logging.psd1')   -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Dotbot.Process/Dotbot.Process.psd1')   -Force -DisableNameChecking
$r = Test-Preflight -BotRoot $BotRoot
@{ passed = [bool]$r.passed; checks = @($r.checks) } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
'@ | Set-Content -Path $childScript

function Invoke-PreflightChild {
    param([Parameter(Mandatory)][string]$Path)
    $resultPath = Join-Path $proj "preflight-result.json"
    Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
    $child = Invoke-ChildPwsh -Path $Path -ArgumentList @(
        '-File', $childScript,
        '-DotbotHome', $dotbotDir,
        '-BotRoot', $botRoot,
        '-WorkDir', $proj,
        '-ResultPath', $resultPath
    )
    $result = $null
    if (Test-Path $resultPath) {
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
    }
    return @{ Output = $child.Output; ExitCode = $child.ExitCode; Result = $result }
}

try {

# ===================================================================
# SECTION 1+2: Test-Preflight must resolve git via registry Machine PATH
# (child PATH: git+claude stripped; tests dir appended so the mock
#  claude.cmd shim isolates the provider check from the git assertion)
# ===================================================================

Write-Host "  PREFLIGHT: GIT VIA REGISTRY PATH (process PATH stripped)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Assert-True -Name "git launcher present in registry Machine/User PATH" `
    -Condition ([bool]$gitInRegistry) `
    -Message "expected git in registry PATH (found: $gitInRegistry)"

$gitStrippedPath = (Get-ProcessPathWithoutCommands -Commands @('git', 'claude')) + ";$PSScriptRoot"
$gitRun = Invoke-PreflightChild -Path $gitStrippedPath

Assert-True -Name "stripped child cannot resolve git via Get-Command (simulation sanity)" `
    -Condition ($gitRun.Output -contains 'SANITY-GIT: False') `
    -Message "child output: $($gitRun.Output -join ' | ')"

Assert-True -Name "stripped child resolves mock claude shim (provider isolation sanity)" `
    -Condition ($gitRun.Output -contains 'SANITY-CLAUDE: True') `
    -Message "child output: $($gitRun.Output -join ' | ')"

Assert-True -Name "Test-Preflight passes when git is only on registry Machine/User PATH" `
    -Condition ($null -ne $gitRun.Result -and $gitRun.Result.passed -eq $true) `
    -Message "checks: $(@($gitRun.Result.checks) -join ' | ')"

Assert-True -Name "Test-Preflight emits no 'git: MISSING' when git is in registry PATH" `
    -Condition ($null -ne $gitRun.Result -and -not (@($gitRun.Result.checks) -match 'git:\s*MISSING')) `
    -Message "checks: $(@($gitRun.Result.checks) -join ' | ')"

$gitLines = @($gitRun.Result.checks) + @($gitRun.Output | ForEach-Object { ConvertTo-SanitizedConsoleText $_ })
Assert-True -Name "preflight output names git and the PATH scope it was found in" `
    -Condition (Test-AnyLineNamesToolAndScope -Tool 'git' -Lines $gitLines) `
    -Message "no line names both git and Machine/User scope. Lines: $($gitLines -join ' | ')"

# ===================================================================
# SECTION 3: Test-Preflight must resolve claude via registry User PATH
# (child PATH: claude stripped, git untouched, no shim)
# ===================================================================

Write-Host ""
Write-Host "  PREFLIGHT: CLAUDE VIA REGISTRY USER PATH" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

if (-not $claudeInUserRegistry) {
    Write-TestResult -Name "claude via registry User PATH" -Status Skip -Message "claude not found in registry User PATH on this machine"
} else {
    $claudeStrippedPath = Get-ProcessPathWithoutCommands -Commands @('claude')
    $claudeRun = Invoke-PreflightChild -Path $claudeStrippedPath

    Assert-True -Name "stripped child resolves git but not claude (simulation sanity)" `
        -Condition (($claudeRun.Output -contains 'SANITY-GIT: True') -and ($claudeRun.Output -contains 'SANITY-CLAUDE: False')) `
        -Message "child output: $($claudeRun.Output -join ' | ')"

    Assert-True -Name "Test-Preflight passes when claude is only on registry User PATH" `
        -Condition ($null -ne $claudeRun.Result -and $claudeRun.Result.passed -eq $true) `
        -Message "checks: $(@($claudeRun.Result.checks) -join ' | ')"

    Assert-True -Name "Test-Preflight emits no 'claude: MISSING' when claude is in registry User PATH" `
        -Condition ($null -ne $claudeRun.Result -and -not (@($claudeRun.Result.checks) -match 'claude:\s*MISSING')) `
        -Message "checks: $(@($claudeRun.Result.checks) -join ' | ')"

    $claudeLines = @($claudeRun.Result.checks) + @($claudeRun.Output | ForEach-Object { ConvertTo-SanitizedConsoleText $_ })
    Assert-True -Name "preflight output names claude and the PATH scope it was found in" `
        -Condition (Test-AnyLineNamesToolAndScope -Tool 'claude' -Lines $claudeLines) `
        -Message "no line names both claude and Machine/User scope. Lines: $($claudeLines -join ' | ')"
}

# ===================================================================
# SECTION 4: 'dotbot doctor' must detect the split, not report MISSING
# ===================================================================

Write-Host ""
Write-Host "  DOCTOR: SPLIT-PATH DETECTION" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$doctorScript = Join-Path $dotbotDir "src/cli/doctor.ps1"
$doctorRun = Invoke-ChildPwsh -Path $gitStrippedPath -ArgumentList @('-File', $doctorScript, '-BotRoot', $botRoot)
$doctorLines = @($doctorRun.Output | ForEach-Object { ConvertTo-SanitizedConsoleText $_ } | Where-Object { $_ })
$doctorText = $doctorLines -join "`n"

Assert-True -Name "doctor runs its dependency checks (sanity)" `
    -Condition ($doctorText -match 'DEPENDENCIES') `
    -Message "doctor output did not contain the DEPENDENCIES section"

Assert-True -Name "doctor does not report git missing when git is in registry PATH" `
    -Condition ($doctorText -notmatch 'git\W*not found on PATH') `
    -Message "doctor still reports git as not found on PATH"

Assert-True -Name "doctor names git and the PATH scope it was found in (split detection)" `
    -Condition (Test-AnyLineNamesToolAndScope -Tool 'git' -Lines $doctorLines) `
    -Message "no doctor line names both git and Machine/User scope"

# ===================================================================
# SECTION 5: 'dotbot doctor' exit code must propagate through the CLI
# (normal PATH — deliberately decoupled from the PATH fix; both
#  scenarios make doctor exit non-zero even after the PATH fix)
# ===================================================================

Write-Host ""
Write-Host "  DOCTOR: EXIT CODE PROPAGATION VIA bin/dotbot.ps1" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$dotbotCli = Join-Path $dotbotDir "bin/dotbot.ps1"

# Scenario A: missing .bot -> doctor.ps1 exits 2 immediately
$missingBot = Join-Path $proj "no-such/.bot"
$null = & $script:PwshExe -NoProfile -NonInteractive -File $doctorScript -BotRoot $missingBot 2>&1
$directExitA = $LASTEXITCODE
$null = & $script:PwshExe -NoProfile -NonInteractive -File $dotbotCli doctor -BotRoot $missingBot 2>&1
$cliExitA = $LASTEXITCODE

Assert-True -Name "direct doctor.ps1 exits non-zero when .bot is missing (sanity)" `
    -Condition ($directExitA -ne 0) `
    -Message "direct exit was $directExitA"

Assert-Equal -Name "'dotbot doctor' exit code equals direct doctor.ps1 exit (missing .bot)" `
    -Expected $directExitA -Actual $cliExitA `
    -Message "bin/dotbot.ps1 swallows doctor.ps1's exit code"

Assert-True -Name "'dotbot doctor' exits non-zero when .bot is missing" `
    -Condition ($cliExitA -ne 0) `
    -Message "CLI exit was $cliExitA"

# Scenario B: invalid task JSON inside a valid project -> doctor exits 2
# via its normal end-of-script exit path
$queueDir = Join-Path $botRoot "workspace/tasks/queue"
New-Item -ItemType Directory -Path $queueDir -Force | Out-Null
"this is not json" | Set-Content -Path (Join-Path $queueDir "bad-task.json")

$null = & $script:PwshExe -NoProfile -NonInteractive -File $doctorScript -BotRoot $botRoot 2>&1
$directExitB = $LASTEXITCODE
$null = & $script:PwshExe -NoProfile -NonInteractive -File $dotbotCli doctor -BotRoot $botRoot 2>&1
$cliExitB = $LASTEXITCODE

Assert-True -Name "direct doctor.ps1 exits non-zero on invalid task JSON (sanity)" `
    -Condition ($directExitB -ne 0) `
    -Message "direct exit was $directExitB"

Assert-Equal -Name "'dotbot doctor' exit code equals direct doctor.ps1 exit (invalid task JSON)" `
    -Expected $directExitB -Actual $cliExitB `
    -Message "bin/dotbot.ps1 swallows doctor.ps1's exit code"

} finally {
    # ===================================================================
    # CLEANUP
    # ===================================================================
    Remove-TestProject -Path $proj
}

# ===================================================================
# SUMMARY
# ===================================================================

$allPassed = Write-TestSummary -LayerName "Layer 2: Dependency PATH Resolution"
if (-not $allPassed) { exit 1 }
