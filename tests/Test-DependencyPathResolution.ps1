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

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally - set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 2: Dependency PATH Resolution"
    exit 1
}

# Dotbot.Core provides the resolver and ConvertTo-SanitizedConsoleText.
$coreModule = Import-Module (Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Core/Dotbot.Core.psd1") -Force -DisableNameChecking -PassThru

# ===================================================================
# GUARDS
# ===================================================================

if (-not $IsWindows) {
    $before = $env:PATH
    $resolution = Resolve-DotbotExternalCommand -Name "dotbot-command-that-does-not-exist-$PID" -RepairSessionPath
    $appended = @(Repair-DotbotProcessPath -Force)
    Assert-True -Name "non-Windows resolver reports registry-only command missing" -Condition (-not $resolution.Found)
    Assert-Equal -Name "non-Windows repair is a no-op" -Expected 0 -Actual $appended.Count
    Assert-Equal -Name "non-Windows repair does not mutate PATH" -Expected $before -Actual $env:PATH
    $allPassed = Write-TestSummary -LayerName "Layer 2: Dependency PATH Resolution"
    if (-not $allPassed) { exit 1 }
    exit 0
}

# ===================================================================
# HELPERS (file-private; only $env:PATH is ever modified, with restore)
# ===================================================================

$script:PwshExe = (Get-Command pwsh).Source
$script:ProbeExtensions = @('ps1', 'com', 'exe', 'bat', 'cmd')

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

# ===================================================================
# SETUP: temp project fixture (bare .bot is enough for Test-Preflight
# to resolve the framework-tier claude provider config via DOTBOT_HOME)
# ===================================================================

$proj = New-TestProject -Prefix "dotbot-test-pathres"
$botRoot = Join-Path $proj ".bot"
New-Item -ItemType Directory -Path $botRoot -Force | Out-Null

$machineDir = Join-Path $proj 'machine-bin'
$userDir = Join-Path $proj 'user-bin'
$safeProcessDir = Join-Path $proj 'safe-process-bin'
$ghUserDir = Join-Path $proj 'gh-user-bin'
New-Item -ItemType Directory -Path $machineDir, $userDir, $safeProcessDir, $ghUserDir -Force | Out-Null
'' | Set-Content -LiteralPath (Join-Path $machineDir 'git.exe')
'"machine"' | Set-Content -LiteralPath (Join-Path $machineDir 'precedence.ps1')
'@echo machine-custom' | Set-Content -LiteralPath (Join-Path $machineDir 'native.custom')
'"user"' | Set-Content -LiteralPath (Join-Path $userDir 'claude.ps1')
'"user"' | Set-Content -LiteralPath (Join-Path $userDir 'precedence.ps1')
'' | Set-Content -LiteralPath (Join-Path $ghUserDir 'gh.exe')

$global:DotbotTestRegistryPaths = @{
    Machine = "`"$machineDir`";relative-bin"
    User    = $userDir
}
$originalRegistryPathReader = $coreModule.SessionState.PSVariable.GetValue('DotbotRegistryPathReader')
$originalElevationReader = $coreModule.SessionState.PSVariable.GetValue('DotbotProcessElevationReader')
$coreModule.SessionState.PSVariable.Set('DotbotRegistryPathReader', {
    param([string]$Scope)
    $global:DotbotTestRegistryPaths[$Scope]
})
$coreModule.SessionState.PSVariable.Set('DotbotProcessElevationReader', { $false })

Write-Host "  CORE: DETERMINISTIC PATH SCOPE + MUTATION RULES" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$oldPath = $env:PATH
$oldPathExt = $env:PATHEXT
$oldSkipRepair = $env:DOTBOT_SKIP_PATH_REPAIR
try {
    $env:PATH = ''
    $env:PATHEXT = '.CUSTOM;.EXE;.BAT;.CMD'
    Remove-Item Env:DOTBOT_SKIP_PATH_REPAIR -ErrorAction SilentlyContinue

    $beforeResolve = $env:PATH
    $machineResolution = Resolve-DotbotExternalCommand -Name 'precedence'
    Assert-Equal -Name "Machine PATH wins over User PATH" -Expected 'Machine' -Actual $machineResolution.Scope
    Assert-Equal -Name "resolution without repair does not mutate PATH" -Expected $beforeResolve -Actual $env:PATH

    $nativeResolution = Resolve-DotbotExternalCommand -Name 'native'
    Assert-True -Name "resolver honors custom PATHEXT entries" -Condition ($nativeResolution.Found)
    Assert-True -Name "resolver reports the PATHEXT-selected source" -Condition ($nativeResolution.Source -like '*.custom')

    $repairResolution = Resolve-DotbotExternalCommand -Name 'precedence' -RepairSessionPath
    Assert-True -Name "targeted registry resolution repairs the session" -Condition $repairResolution.Repaired
    Assert-Equal -Name "empty PATH repair has no leading empty segment" -Expected $machineDir -Actual $env:PATH
    Assert-True -Name "targeted repair does not add unrelated User PATH" -Condition ($env:PATH -notlike "*$userDir*")

    $env:PATH = ''
    $appended = @(Repair-DotbotProcessPath -Force)
    $expectedMergedPath = "$machineDir;$userDir"
    Assert-Equal -Name "full repair preserves Machine then User precedence" -Expected $expectedMergedPath -Actual $env:PATH
    Assert-Equal -Name "full repair reports only accepted absolute directories" -Expected 2 -Actual $appended.Count
    Assert-True -Name "relative registry entries are not added to PATH" -Condition ($env:PATH -notmatch 'relative-bin')

    $env:PATH = $safeProcessDir
    $env:DOTBOT_SKIP_PATH_REPAIR = '1'
    $skipBefore = $env:PATH
    $skippedResolution = Resolve-DotbotExternalCommand -Name 'claude' -RepairSessionPath
    $skippedFullRepair = @(Repair-DotbotProcessPath -Force)
    Assert-True -Name "opt-out still detects a User PATH command" -Condition ($skippedResolution.Found -and $skippedResolution.Scope -eq 'User')
    Assert-True -Name "opt-out prevents targeted repair" -Condition (-not $skippedResolution.Repaired)
    Assert-Equal -Name "opt-out prevents every PATH mutation path" -Expected $skipBefore -Actual $env:PATH
    Assert-Equal -Name "opt-out full repair appends nothing" -Expected 0 -Actual $skippedFullRepair.Count

    Remove-Item Env:DOTBOT_SKIP_PATH_REPAIR -ErrorAction SilentlyContinue
    $coreModule.SessionState.PSVariable.Set('DotbotProcessElevationReader', { $true })
    $env:PATH = $safeProcessDir
    $elevatedResolution = Resolve-DotbotExternalCommand -Name 'claude' -RepairSessionPath
    $elevatedRepair = @(Repair-DotbotProcessPath -Force)
    Assert-True -Name "elevated process detects User PATH command without repairing" `
        -Condition ($elevatedResolution.Found -and -not $elevatedResolution.Repaired -and $elevatedResolution.RepairBlocked -eq 'elevated_user_path')
    Assert-True -Name "elevated full repair excludes User PATH" -Condition ($env:PATH -notlike "*$userDir*")
    Assert-True -Name "elevated full repair may still add Machine PATH" -Condition ($elevatedRepair -contains $machineDir)
} finally {
    $env:PATH = $oldPath
    $env:PATHEXT = $oldPathExt
    if ($null -eq $oldSkipRepair) { Remove-Item Env:DOTBOT_SKIP_PATH_REPAIR -ErrorAction SilentlyContinue }
    else { $env:DOTBOT_SKIP_PATH_REPAIR = $oldSkipRepair }
    $coreModule.SessionState.PSVariable.Set('DotbotRegistryPathReader', $originalRegistryPathReader)
    $coreModule.SessionState.PSVariable.Set('DotbotProcessElevationReader', $originalElevationReader)
    Remove-Variable DotbotTestRegistryPaths -Scope Global -ErrorAction SilentlyContinue
}

# Child script: reports what Get-Command sees, runs Test-Preflight, writes JSON
$childScript = Join-Path $proj "run-preflight.ps1"
@'
param(
    [Parameter(Mandatory)][string]$DotbotHome,
    [Parameter(Mandatory)][string]$BotRoot,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$MachinePath,
    [Parameter(Mandatory)][string]$UserPath,
    [switch]$SkipRepair
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $WorkDir
"SANITY-GIT: $([bool](Get-Command git -ErrorAction SilentlyContinue))"
"SANITY-CLAUDE: $([bool](Get-Command claude -ErrorAction SilentlyContinue))"
$modules = Join-Path $DotbotHome 'src/runtime/Modules'
$core = Import-Module (Join-Path $modules 'Dotbot.Core/Dotbot.Core.psd1') -Force -DisableNameChecking -PassThru
$global:DotbotTestRegistryPaths = @{ Machine = $MachinePath; User = $UserPath }
$core.SessionState.PSVariable.Set('DotbotRegistryPathReader', {
    param([string]$Scope)
    $global:DotbotTestRegistryPaths[$Scope]
})
$core.SessionState.PSVariable.Set('DotbotProcessElevationReader', { $false })
if ($SkipRepair) { $env:DOTBOT_SKIP_PATH_REPAIR = '1' }
Import-Module (Join-Path $modules 'Dotbot.Settings/Dotbot.Settings.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Dotbot.Logging/Dotbot.Logging.psd1')   -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Dotbot.Process/Dotbot.Process.psd1')   -Force -DisableNameChecking
$r = Test-Preflight -BotRoot $BotRoot
@{ passed = [bool]$r.passed; checks = @($r.checks) } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath
'@ | Set-Content -Path $childScript

function Invoke-PreflightChild {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$SkipRepair
    )
    $resultPath = Join-Path $proj "preflight-result.json"
    Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
    $childArgs = @(
        '-File', $childScript,
        '-DotbotHome', $dotbotDir,
        '-BotRoot', $botRoot,
        '-WorkDir', $proj,
        '-ResultPath', $resultPath,
        '-MachinePath', $machineDir,
        '-UserPath', $userDir
    )
    if ($SkipRepair) { $childArgs += '-SkipRepair' }
    $child = Invoke-ChildPwsh -Path $Path -ArgumentList $childArgs
    $result = $null
    if (Test-Path $resultPath) {
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
    }
    return @{ Output = $child.Output; ExitCode = $child.ExitCode; Result = $result }
}

$doctorBootstrap = Join-Path $proj 'run-doctor.ps1'
@'
param(
    [Parameter(Mandatory)][string]$DotbotHome,
    [Parameter(Mandatory)][string]$BotRoot,
    [Parameter(Mandatory)][string]$MachinePath,
    [Parameter(Mandatory)][string]$UserPath
)
$core = Import-Module (Join-Path $DotbotHome 'src/runtime/Modules/Dotbot.Core/Dotbot.Core.psd1') -Force -DisableNameChecking -PassThru
$global:DotbotTestRegistryPaths = @{ Machine = $MachinePath; User = $UserPath }
$core.SessionState.PSVariable.Set('DotbotRegistryPathReader', {
    param([string]$Scope)
    $global:DotbotTestRegistryPaths[$Scope]
})
& (Join-Path $DotbotHome 'src/cli/doctor.ps1') -BotRoot $BotRoot
'@ | Set-Content -LiteralPath $doctorBootstrap

try {

# ===================================================================
# SECTION 1+2: Test-Preflight must resolve git via registry Machine PATH
# (child PATH: git+claude stripped; tests dir appended so the mock
#  claude.cmd shim isolates the provider check from the git assertion)
# ===================================================================

Write-Host "  PREFLIGHT: GIT VIA REGISTRY PATH (process PATH stripped)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Assert-True -Name "mock git launcher present in Machine PATH fixture" `
    -Condition (Test-Path -LiteralPath (Join-Path $machineDir 'git.exe'))

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

$claudeStrippedPath = $machineDir
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

$optOutRun = Invoke-PreflightChild -Path $machineDir -SkipRepair
Assert-True -Name "preflight fails cleanly when User PATH repair is opted out" `
    -Condition ($null -ne $optOutRun.Result -and $optOutRun.Result.passed -eq $false)
Assert-True -Name "preflight explains the PATH-repair opt-out" `
    -Condition ([bool](@($optOutRun.Result.checks) -match 'DOTBOT_SKIP_PATH_REPAIR')) `
    -Message "checks: $(@($optOutRun.Result.checks) -join ' | ')"

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

$ghDoctorRun = Invoke-ChildPwsh -Path $safeProcessDir -ArgumentList @(
    '-File', $doctorBootstrap,
    '-DotbotHome', $dotbotDir,
    '-BotRoot', $botRoot,
    '-MachinePath', $machineDir,
    '-UserPath', $ghUserDir
)
$ghDoctorLines = @($ghDoctorRun.Output | ForEach-Object { ConvertTo-SanitizedConsoleText $_ } | Where-Object { $_ })
$ghDoctorText = $ghDoctorLines -join "`n"
Assert-True -Name "doctor diagnoses registry-only gh as split PATH" `
    -Condition ($ghDoctorText -match 'Provider CLI \(gh\).*split PATH detected') `
    -Message "doctor output: $ghDoctorText"
Assert-True -Name "doctor does not report registry-only gh as an ordinary pass" `
    -Condition ($ghDoctorText -notmatch "Provider CLI.*gh found \(can run preview") `
    -Message "doctor output: $ghDoctorText"

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
