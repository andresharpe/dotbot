#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: transition hooks tests.
.DESCRIPTION
    Covers the public surface of Dotbot.Hook:

      - Discovery: fixture directory with three valid hooks + one malformed →
        three registered, malformed produces a startup error.
      - Dispatch: -ToStatus done invokes done-targeted hooks; -ToStatus
        skipped invokes none if no hook targets it.
      - Timeout: fixture hook with max_duration: 1 that sleeps 5 → dispatcher
        kills it within bounded time; failure is reported.
      - Abort behaviour: abort_on_failure: true hook returns failure → caller
        is told to revert; abort_on_failure: false hook returns failure →
        caller is told to proceed.
      - Shipped hooks: round-trip — the framework's enter-in-progress /
        enter-done / enter-failed / enter-skipped / enter-cancelled are
        discoverable and complete their contract when invoked.
      - End-to-end: POST /tasks/<id>/status with an aborting hook → 422
        hook_aborted; task is reverted on disk; activity.jsonl carries the
        hook_failed event.

    Test fixtures are tmp directories with throwaway script.ps1 files that
    encode their behaviour declaratively (return success/fail, sleep N).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Plugin transition hooks" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1") -Force -DisableNameChecking -Global
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking -Global
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Hook/Dotbot.Hook.psd1") -Force -DisableNameChecking -Global
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1") -Force -DisableNameChecking -Global

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

# ─── Fixture builder ────────────────────────────────────────────────────────

function New-HookFixtureDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-prd06-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-HookFixture {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string[]]$Targets,
        [int]$MaxDuration = 5,
        [bool]$AbortOnFailure = $false,
        [string]$ScriptBody = '@{ Success = $true; Message = "ok"; Duration = [TimeSpan]::Zero }'
    )

    $hookDir = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null

    $targetsJson = "[" + (($Targets | ForEach-Object { '"' + $_ + '"' }) -join ', ') + "]"
    $abortStr = if ($AbortOnFailure) { 'true' } else { 'false' }
    $meta = @"
{
  "name": "$Name",
  "description": "test fixture",
  "target_statuses": $targetsJson,
  "max_duration": $MaxDuration,
  "abort_on_failure": $abortStr
}
"@
    Set-Content -Path (Join-Path $hookDir 'metadata.json') -Value $meta -Encoding utf8NoBOM

    $script = @"
function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]`$Task,
        [Parameter(Mandatory)][hashtable]`$RunContext,
        [Parameter(Mandatory)][string]`$FromStatus,
        [Parameter(Mandatory)][string]`$ToStatus
    )
    $ScriptBody
}
Export-ModuleMember -Function Invoke-Hook
"@
    Set-Content -Path (Join-Path $hookDir 'script.ps1') -Value $script -Encoding utf8NoBOM
}

# ═══════════════════════════════════════════════════════════════════════════
# Discovery
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Discovery: scan + parse + index by target status" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fixtureRoot = New-HookFixtureDir
try {
    New-HookFixture -Root $fixtureRoot -Name 'a-enter-done'     -Targets 'done'
    New-HookFixture -Root $fixtureRoot -Name 'b-enter-failed'   -Targets 'failed'
    New-HookFixture -Root $fixtureRoot -Name 'c-enter-multi'    -Targets 'done','failed','skipped'

    $reg = Get-HookRegistry -HooksDir $fixtureRoot
    Assert-Equal -Name "Registry returns 3 valid hooks" -Expected 3 -Actual $reg.Count

    # Alphabetical / declaration order (Get-ChildItem -Directory + Sort-Object Name).
    Assert-Equal -Name "Hook order: first is a-enter-done"     -Expected 'a-enter-done'   -Actual $reg[0].name
    Assert-Equal -Name "Hook order: last is c-enter-multi"     -Expected 'c-enter-multi'  -Actual $reg[2].name

    $doneHooks = Get-HooksForStatus -Registry $reg -ToStatus 'done'
    Assert-Equal -Name "Get-HooksForStatus(done) returns 2 hooks" -Expected 2 -Actual $doneHooks.Count

    $skippedHooks = Get-HooksForStatus -Registry $reg -ToStatus 'skipped'
    Assert-Equal -Name "Get-HooksForStatus(skipped) returns 1 hook" -Expected 1 -Actual $skippedHooks.Count

    $todoHooks = Get-HooksForStatus -Registry $reg -ToStatus 'todo'
    Assert-Equal -Name "Get-HooksForStatus(todo) returns 0 hooks" -Expected 0 -Actual $todoHooks.Count

    # Malformed: a hook directory missing script.ps1 → throws.
    $bad = Join-Path $fixtureRoot 'd-malformed'
    New-Item -ItemType Directory -Path $bad -Force | Out-Null
    Set-Content -Path (Join-Path $bad 'metadata.json') -Value '{"name":"d-malformed","target_statuses":["done"],"max_duration":5,"abort_on_failure":false}' -Encoding utf8NoBOM
    Assert-Throws -Name "Malformed hook (missing script.ps1) throws at discovery" `
        -Action { Get-HookRegistry -HooksDir $fixtureRoot } `
        -Pattern 'script.ps1'

    # Empty dir → empty registry, not an error.
    Remove-Item -LiteralPath $bad -Recurse -Force
    $empty = New-HookFixtureDir
    try {
        $emptyReg = Get-HookRegistry -HooksDir $empty
        Assert-Equal -Name "Empty hooks dir returns empty registry" -Expected 0 -Actual $emptyReg.Count
    } finally { Remove-Item -LiteralPath $empty -Recurse -Force }

    # Missing dir → empty registry too (callers can ship without a hooks dir).
    $missing = Join-Path $fixtureRoot 'does-not-exist'
    $missingReg = Get-HookRegistry -HooksDir $missing
    Assert-Equal -Name "Missing hooks dir returns empty registry" -Expected 0 -Actual $missingReg.Count

} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# Dispatch
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Dispatch: invoke matching hooks; route by ToStatus" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fx = New-HookFixtureDir
try {
    New-HookFixture -Root $fx -Name 'on-done'  -Targets 'done'   -ScriptBody '@{ Success = $true; Message = "fired on done"; Duration = [TimeSpan]::Zero }'
    New-HookFixture -Root $fx -Name 'on-failed' -Targets 'failed' -ScriptBody '@{ Success = $true; Message = "fired on failed"; Duration = [TimeSpan]::Zero }'

    $fakeTask = @{ id = 't_aaaaaaaa'; status = 'done'; provenance = @{ run_id = $null } }

    $r = Invoke-TransitionHooks -HooksDir $fx -ToStatus 'done' -FromStatus 'in-progress' -Task $fakeTask
    Assert-Equal -Name "Dispatch to 'done' fires exactly one hook" -Expected 1 -Actual $r.hook_results.Count
    Assert-Equal -Name "Dispatch to 'done' fires the right hook"   -Expected 'on-done' -Actual $r.hook_results[0].name
    Assert-True  -Name "Dispatch to 'done' reports success"        -Condition ([bool]$r.hook_results[0].success)
    Assert-True  -Name "Dispatch to 'done' is not aborted"         -Condition (-not $r.aborted)

    $r = Invoke-TransitionHooks -HooksDir $fx -ToStatus 'skipped' -FromStatus 'todo' -Task $fakeTask
    Assert-Equal -Name "Dispatch to 'skipped' fires no hooks (none target it)" -Expected 0 -Actual $r.hook_results.Count

} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# Timeout
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Timeout: max_duration enforced via runspace stop" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fx = New-HookFixtureDir
try {
    New-HookFixture -Root $fx -Name 'sleeper' -Targets 'done' -MaxDuration 1 -AbortOnFailure $true `
        -ScriptBody 'Start-Sleep -Seconds 5; @{ Success = $true; Message = "should never reach"; Duration = [TimeSpan]::Zero }'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-TransitionHooks -HooksDir $fx -ToStatus 'done' -FromStatus 'in-progress' -Task @{ id = 't_aaaaaaaa' }
    $sw.Stop()

    Assert-True -Name "Timeout completes within 3s (well under the script's 5s)" `
        -Condition ($sw.Elapsed.TotalSeconds -lt 3.5)
    Assert-Equal -Name "Timeout produces exactly 1 hook result" -Expected 1 -Actual $r.hook_results.Count
    Assert-True  -Name "Timed-out hook is marked failed"        -Condition (-not $r.hook_results[0].success)
    Assert-True  -Name "Timed-out hook reports timed_out=true"  -Condition ([bool]$r.hook_results[0].timed_out)
    Assert-True  -Name "Timeout aborts when abort_on_failure: true" -Condition $r.aborted
    Assert-Equal -Name "Timeout names the failing hook"          -Expected 'sleeper' -Actual $r.failing_hook
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# Abort behaviour
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Abort behaviour: true → revert; false → proceed" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fx = New-HookFixtureDir
try {
    # abort_on_failure: true + hook returns failure → caller told to revert
    New-HookFixture -Root $fx -Name 'failer-abort' -Targets 'done' -AbortOnFailure $true `
        -ScriptBody '@{ Success = $false; Message = "intentional failure"; Duration = [TimeSpan]::Zero }'
    $r = Invoke-TransitionHooks -HooksDir $fx -ToStatus 'done' -FromStatus 'in-progress' -Task @{ id = 't_aaaaaaaa' }
    Assert-True  -Name "Aborting hook causes aborted=true"      -Condition $r.aborted
    Assert-Equal -Name "Aborting hook is named"                  -Expected 'failer-abort' -Actual $r.failing_hook
    Assert-True  -Name "Aborting hook message is propagated"    -Condition ($r.failing_message -match 'intentional failure')

    # Remove the aborter; replace with advisory failure
    Remove-Item -LiteralPath (Join-Path $fx 'failer-abort') -Recurse -Force
    New-HookFixture -Root $fx -Name 'failer-advisory' -Targets 'done' -AbortOnFailure $false `
        -ScriptBody '@{ Success = $false; Message = "advisory failure"; Duration = [TimeSpan]::Zero }'
    $r = Invoke-TransitionHooks -HooksDir $fx -ToStatus 'done' -FromStatus 'in-progress' -Task @{ id = 't_aaaaaaaa' }
    Assert-True  -Name "Advisory failure does NOT abort"        -Condition (-not $r.aborted)
    Assert-True  -Name "Advisory failure still produces a result with success=false" `
        -Condition ((-not $r.hook_results[0].success) -and ($r.hook_results[0].name -eq 'failer-advisory'))

    # Throwing hook with abort_on_failure: true → still aborts
    Remove-Item -LiteralPath (Join-Path $fx 'failer-advisory') -Recurse -Force
    New-HookFixture -Root $fx -Name 'thrower' -Targets 'done' -AbortOnFailure $true `
        -ScriptBody 'throw "boom"'
    $r = Invoke-TransitionHooks -HooksDir $fx -ToStatus 'done' -FromStatus 'in-progress' -Task @{ id = 't_aaaaaaaa' }
    Assert-True  -Name "Thrown exception aborts when abort_on_failure: true" -Condition $r.aborted
    Assert-True  -Name "Thrown exception message reaches failing_message"   -Condition ($r.failing_message -match 'boom')
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# Shipped hooks (smoke)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Shipped hooks: discovery + smoke invoke" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$shippedDir = Join-Path $repoRoot 'src/runtime/Plugins/Hooks/Transitions'
$reg = Get-HookRegistry -HooksDir $shippedDir
$shippedNames = @($reg | ForEach-Object { $_.name })
foreach ($expected in @('enter-in-progress','enter-done','enter-failed','enter-skipped','enter-cancelled')) {
    Assert-True -Name "Shipped registry contains '$expected'" -Condition ($shippedNames -contains $expected)
}

# Smoke-run enter-skipped — it's the simplest (no side effects, no BotRoot needed).
$dummy = @{ id = 't_aaaaaaaa'; status = 'skipped'; provenance = @{ run_id = $null } }
$r = Invoke-TransitionHooks -HooksDir $shippedDir -ToStatus 'skipped' -FromStatus 'todo' -Task $dummy
Assert-True -Name "enter-skipped smoke: aborted=false"          -Condition (-not $r.aborted)
Assert-True -Name "enter-skipped smoke: at least one result"    -Condition ($r.hook_results.Count -ge 1)
$skipResult = $r.hook_results | Where-Object { $_.name -eq 'enter-skipped' } | Select-Object -First 1
Assert-True -Name "enter-skipped smoke: hook reports success"   -Condition ([bool]$skipResult.success)

# ═══════════════════════════════════════════════════════════════════════════
# #628: enter-done resolves the verify chain's cwd, not the launch cwd
# ═══════════════════════════════════════════════════════════════════════════
#
# 01-git-clean.ps1 (and the rest of the verify chain) run `git status`
# relative to the process's current directory. Before the #628 fix,
# `pwsh -File` inherited whatever directory the runtime happened to be
# launched from — wrong whenever that isn't the task's project. These
# tests drive enter-done's actual script.ps1 (not a fixture stand-in) as a
# fresh, unimported pwsh child process — same isolation the real dispatcher
# runspace has (Dispatch.psm1 creates one PowerShell instance per hook with
# no shared module state) — so the lazy Import-Module branches for
# Dotbot.Content / Dotbot.Worktree are genuinely exercised, not bypassed by
# modules this test file already imported above.

Write-Host ""
Write-Host "  #628: verify chain cwd resolution (worktree / working_directory / botRoot)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$enterDoneScript = Join-Path $repoRoot "src/runtime/Plugins/Hooks/Transitions/enter-done/script.ps1"

function ConvertTo-PSSingleQuoteLiteral {
    # Escapes a value for safe embedding inside a single-quoted PowerShell
    # string literal in generated source (the stub bodies and out-of-process
    # runner scripts below build .ps1 source as text). PowerShell's escape
    # for a literal ' inside '...' is '' — without this, any temp/worktree
    # path containing an apostrophe (rare but valid on Windows/macOS/Linux,
    # e.g. a user profile folder) would terminate the string early and make
    # the generated script syntactically invalid, failing the test for
    # reasons unrelated to cwd resolution.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Value)
    return $Value.Replace("'", "''")
}

function New-Issue628FixtureDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-628-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-VerifyCwdStubBotRoot {
    # Overrides every real framework verify script name with a stub that just
    # records (Get-Location).Path to $MarkerFile and reports success. Project
    # hooks win over framework ones for the same filename (Get-DotbotHookChain),
    # so this fully isolates the test from real verify logic (gitleaks, git
    # state, md refs, ...) and gives an unambiguous signal of which directory
    # Push-Location actually targeted.
    param(
        [Parameter(Mandatory)] [string]$FixtureRoot,
        [Parameter(Mandatory)] [string]$MarkerFile
    )
    $botRootDir     = Join-Path $FixtureRoot 'botroot'
    $hooksVerifyDir = Join-Path $botRootDir 'hooks/verify'
    New-Item -ItemType Directory -Force -Path $hooksVerifyDir, (Join-Path $botRootDir '.control') | Out-Null

    $stubBody = @'
param([string]$TaskId, [string]$Category)
Add-Content -LiteralPath '__MARKER__' -Value (Get-Location).Path
@{ success = $true; script = 'stub'; message = 'stub ok' } | ConvertTo-Json
'@.Replace('__MARKER__', (ConvertTo-PSSingleQuoteLiteral $MarkerFile))

    foreach ($name in @('00-privacy-scan.ps1','01-git-clean.ps1','02-git-pushed.ps1','03-check-md-refs.ps1','04-framework-integrity.ps1')) {
        Set-Content -LiteralPath (Join-Path $hooksVerifyDir $name) -Value $stubBody -Encoding utf8NoBOM
    }
    return $botRootDir
}

function Set-Issue628WorktreeMapEntry {
    # Hand-writes <BotRoot>/.control/worktree-map.json — the format
    # Read-WorktreeMap expects (a JSON object keyed by TaskId) — without
    # needing Dotbot.Worktree imported in this test process.
    param(
        [Parameter(Mandatory)] [string]$BotRootDir,
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string]$WorktreePath
    )
    $map = @{
        $TaskId = @{
            worktree_path = $WorktreePath
            branch_name   = "task/$TaskId"
            task_name     = "fixture task"
            created_at    = "2026-07-13T00:00:00Z"
        }
    }
    $map | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $BotRootDir '.control/worktree-map.json') -Encoding utf8NoBOM
}

function Invoke-EnterDoneOutOfProcess {
    # Runs enter-done's real Invoke-Hook in a brand-new pwsh process (no
    # preloaded modules), launched from an arbitrary directory — reproducing
    # both halves of the #628 bug scenario (wrong launch cwd; fresh runspace
    # module state) in one call.
    #
    # -ProvenanceAsPSObject builds $Task.provenance as [pscustomobject] instead
    # of [hashtable] to exercise the `$prov.PSObject.Properties['run_id']`
    # fallback branch. Today's only production caller (HttpServer.psm1's
    # Invoke-TaskStatusHandler) reads tasks via ConvertFrom-Json -AsHashtable,
    # so provenance always arrives as a nested hashtable in practice — this
    # covers the defensive branch in case another caller ever constructs
    # $Task differently (it mirrors the same dual-branch check already shipped
    # in enter-in-progress/script.ps1).
    param(
        [Parameter(Mandatory)] [string]$RunnerPath,
        [Parameter(Mandatory)] [string]$TaskId,
        [string]$RunId,
        [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string]$BotRootDir,
        [switch]$ProvenanceAsPSObject,
        [string]$LaunchCwd = ([System.IO.Path]::GetTempPath())
    )

    $runIdLiteral   = if ($RunId)            { "'$(ConvertTo-PSSingleQuoteLiteral $RunId)'" }            else { '$null' }
    $workDirLiteral = if ($WorkingDirectory) { "'$(ConvertTo-PSSingleQuoteLiteral $WorkingDirectory)'" } else { '$null' }
    $provenanceLiteral = if ($ProvenanceAsPSObject) {
        "[pscustomobject]@{ run_id = $runIdLiteral }"
    } else {
        "@{ run_id = $runIdLiteral }"
    }

    $repoRootLiteral       = ConvertTo-PSSingleQuoteLiteral $repoRoot
    $enterDoneScriptLiteral = ConvertTo-PSSingleQuoteLiteral $enterDoneScript
    $taskIdLiteral         = ConvertTo-PSSingleQuoteLiteral $TaskId
    $botRootDirLiteral     = ConvertTo-PSSingleQuoteLiteral $BotRootDir

    # Load script.ps1 the same way Dispatch.psm1's Invoke-SingleTransitionHook
    # actually does in production — build a dynamic module from a scriptblock
    # of the file's content — rather than dot-sourcing or Import-Module on a
    # bare .ps1 (neither gives Export-ModuleMember a real module scope, so
    # both throw "can only be called from inside a module" as a non-terminating
    # error that would otherwise need to be swallowed with 2>$null).
    $runner = @"
`$env:DOTBOT_HOME = '$repoRootLiteral'
`$content = Get-Content -LiteralPath '$enterDoneScriptLiteral' -Raw
`$sb = [ScriptBlock]::Create(`$content)
`$mod = New-Module -Name 'EnterDoneUnderTest' -ScriptBlock `$sb
`$task = @{
    id                = '$taskIdLiteral'
    category          = 'test'
    provenance        = $provenanceLiteral
    working_directory = $workDirLiteral
}
`$runContext = @{ BotRoot = '$botRootDirLiteral' }
`$result = & `$mod Invoke-Hook -Task `$task -RunContext `$runContext -FromStatus 'in-progress' -ToStatus 'done'
`$result | ConvertTo-Json -Depth 5 -Compress
"@
    Set-Content -LiteralPath $RunnerPath -Value $runner -Encoding utf8NoBOM

    Push-Location -LiteralPath $LaunchCwd
    try {
        $out = & pwsh -NoProfile -File $RunnerPath
    } finally {
        Pop-Location
    }
    try { return ($out -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Assert-VerifyCwdMarker {
    # Asserts the whole verify chain (all 5 stubs) ran in exactly $ExpectedDir.
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$MarkerFile,
        [Parameter(Mandatory)] [string]$ExpectedDir
    )
    $lines = if (Test-Path -LiteralPath $MarkerFile) { @(Get-Content -LiteralPath $MarkerFile) } else { @() }
    Assert-Equal -Name "$Name`: verify chain ran (5 stub hooks recorded cwd)" -Expected 5 -Actual $lines.Count
    Assert-Equal -Name "$Name`: verify chain cwd" -Expected $ExpectedDir -Actual ($lines | Select-Object -First 1) `
        -Message "Expected every stub to run in '$ExpectedDir', got: $($lines -join ', ')"
    Assert-True -Name "$Name`: cwd consistent across the whole chain" `
        -Condition (@($lines | Select-Object -Unique).Count -eq 1)
}

# --- Scenario 1: worktree registry entry exists and is valid → worktree_path wins
$fx = New-Issue628FixtureDir
try {
    $marker      = Join-Path $fx 'marker.txt'
    $worktreeDir = Join-Path $fx 'worktree'
    $workingDir  = Join-Path $fx 'workingdir'
    New-Item -ItemType Directory -Force -Path $worktreeDir, $workingDir | Out-Null
    $botRootDir = New-VerifyCwdStubBotRoot -FixtureRoot $fx -MarkerFile $marker
    Set-Issue628WorktreeMapEntry -BotRootDir $botRootDir -TaskId 't_628scn1' -WorktreePath $worktreeDir

    $r = Invoke-EnterDoneOutOfProcess -RunnerPath (Join-Path $fx 'runner.ps1') `
        -TaskId 't_628scn1' -RunId 'wr_628scn1' -WorkingDirectory $workingDir -BotRootDir $botRootDir
    Assert-True -Name "Scenario 1 (valid worktree): Invoke-Hook succeeds" -Condition ([bool]$r.Success)
    Assert-VerifyCwdMarker -Name "Scenario 1 (valid worktree)" -MarkerFile $marker -ExpectedDir $worktreeDir
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 1b: same as Scenario 1, but provenance arrives as a PSCustomObject
#     (e.g. plain ConvertFrom-Json without -AsHashtable) instead of a hashtable
$fx = New-Issue628FixtureDir
try {
    $marker      = Join-Path $fx 'marker.txt'
    $worktreeDir = Join-Path $fx 'worktree'
    $workingDir  = Join-Path $fx 'workingdir'
    New-Item -ItemType Directory -Force -Path $worktreeDir, $workingDir | Out-Null
    $botRootDir = New-VerifyCwdStubBotRoot -FixtureRoot $fx -MarkerFile $marker
    Set-Issue628WorktreeMapEntry -BotRootDir $botRootDir -TaskId 't_628scn1b' -WorktreePath $worktreeDir

    $r = Invoke-EnterDoneOutOfProcess -RunnerPath (Join-Path $fx 'runner.ps1') `
        -TaskId 't_628scn1b' -RunId 'wr_628scn1b' -WorkingDirectory $workingDir -BotRootDir $botRootDir `
        -ProvenanceAsPSObject
    Assert-True -Name "Scenario 1b (PSCustomObject provenance): Invoke-Hook succeeds" -Condition ([bool]$r.Success)
    Assert-VerifyCwdMarker -Name "Scenario 1b (PSCustomObject provenance, valid worktree)" -MarkerFile $marker -ExpectedDir $worktreeDir
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 2: worktree registry entry exists but worktree_path is gone from
#     disk (Test-Path guard) → falls back to working_directory
$fx = New-Issue628FixtureDir
try {
    $marker      = Join-Path $fx 'marker.txt'
    $missingWorktreeDir = Join-Path $fx 'worktree-deleted'
    $workingDir  = Join-Path $fx 'workingdir'
    New-Item -ItemType Directory -Force -Path $workingDir | Out-Null
    # Deliberately never create $missingWorktreeDir — registry points at a
    # worktree that's already been discarded (e.g. Reset-TaskWorktree ran).
    $botRootDir = New-VerifyCwdStubBotRoot -FixtureRoot $fx -MarkerFile $marker
    Set-Issue628WorktreeMapEntry -BotRootDir $botRootDir -TaskId 't_628scn2' -WorktreePath $missingWorktreeDir

    $r = Invoke-EnterDoneOutOfProcess -RunnerPath (Join-Path $fx 'runner.ps1') `
        -TaskId 't_628scn2' -RunId 'wr_628scn2' -WorkingDirectory $workingDir -BotRootDir $botRootDir
    Assert-True -Name "Scenario 2 (stale worktree entry): Invoke-Hook succeeds" -Condition ([bool]$r.Success)
    Assert-VerifyCwdMarker -Name "Scenario 2 (stale worktree entry falls back)" -MarkerFile $marker -ExpectedDir $workingDir
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 3: no provenance/run_id (standalone task) → working_directory,
#     worktree registry never consulted
$fx = New-Issue628FixtureDir
try {
    $marker     = Join-Path $fx 'marker.txt'
    $workingDir = Join-Path $fx 'workingdir'
    New-Item -ItemType Directory -Force -Path $workingDir | Out-Null
    $botRootDir = New-VerifyCwdStubBotRoot -FixtureRoot $fx -MarkerFile $marker
    # No worktree-map.json entry at all — a standalone task has nothing to look up.

    $r = Invoke-EnterDoneOutOfProcess -RunnerPath (Join-Path $fx 'runner.ps1') `
        -TaskId 't_628scn3' -RunId $null -WorkingDirectory $workingDir -BotRootDir $botRootDir
    Assert-True -Name "Scenario 3 (no run_id): Invoke-Hook succeeds" -Condition ([bool]$r.Success)
    Assert-VerifyCwdMarker -Name "Scenario 3 (no run_id uses working_directory)" -MarkerFile $marker -ExpectedDir $workingDir
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Scenario 4: no run_id AND working_directory doesn't exist on disk → botRoot
$fx = New-Issue628FixtureDir
try {
    $marker           = Join-Path $fx 'marker.txt'
    $missingWorkingDir = Join-Path $fx 'workingdir-does-not-exist'
    $botRootDir = New-VerifyCwdStubBotRoot -FixtureRoot $fx -MarkerFile $marker
    # Deliberately never create $missingWorkingDir.

    $r = Invoke-EnterDoneOutOfProcess -RunnerPath (Join-Path $fx 'runner.ps1') `
        -TaskId 't_628scn4' -RunId $null -WorkingDirectory $missingWorkingDir -BotRootDir $botRootDir
    Assert-True -Name "Scenario 4 (nothing valid): Invoke-Hook succeeds" -Condition ([bool]$r.Success)
    Assert-VerifyCwdMarker -Name "Scenario 4 (falls all the way back to botRoot)" -MarkerFile $marker -ExpectedDir $botRootDir
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# End-to-end: HTTP /tasks/<id>/status with aborting hook reverts on disk
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  End-to-end: aborting hook reverts the transition" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

function New-RuntimeTestBot {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-prd06rt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $bot  = Join-Path $base '.bot'
    New-Item -ItemType Directory -Path $bot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bot '.control') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bot 'workspace/tasks') -Force | Out-Null
    Push-Location -LiteralPath $base
    try {
        & git init -q | Out-Null
        & git config user.email "t@example.com" | Out-Null
        & git config user.name  "t" | Out-Null
        New-Item -Path (Join-Path $base 'README.md') -ItemType File -Value 'x' -Force | Out-Null
        & git add . | Out-Null
        & git -c commit.gpgsign=false commit -q -m "init" | Out-Null
    } finally { Pop-Location }
    return $bot
}

function Invoke-Raw {
    param([string]$Url, [string]$Method, [string]$Path, [string]$Token, $Body)
    $h = @{ Authorization = "Bearer $Token" }
    $p = @{
        Uri = ($Url.TrimEnd('/') + $Path)
        Method = $Method
        Headers = $h
        SkipHttpErrorCheck = $true
        TimeoutSec = 15
    }
    if ($Body -and $Method -ne 'GET') {
        $p['Body'] = ($Body | ConvertTo-Json -Depth 20)
        $p['ContentType'] = 'application/json; charset=utf-8'
    }
    $resp = Invoke-WebRequest @p
    $parsed = $null
    try { $parsed = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    return @{ status_code = [int]$resp.StatusCode; body = $parsed }
}

$bot = New-RuntimeTestBot
$start = $null
try {
    # Seed an "aborter on done" hook fixture into the project's own hooks dir
    # so the runtime's default discovery path picks it up (no env override
    # plumbing needed for the runtime).
    $projectHookDir = Join-Path $bot (Join-Path 'src' (Join-Path 'runtime' (Join-Path 'Plugins' (Join-Path 'Hooks' 'Transitions'))))
    New-Item -ItemType Directory -Path $projectHookDir -Force | Out-Null
    New-HookFixture -Root $projectHookDir -Name 'enter-done' -Targets 'done' -AbortOnFailure $true `
        -ScriptBody '@{ Success = $false; Message = "verify says no"; Duration = [TimeSpan]::Zero }'

    $start = Start-DotbotRuntime -BotRoot $bot
    # Wait for ready
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { (Invoke-Raw -Url $start.url -Method GET -Path '/health' -Token $start.token) | Out-Null; break }
        catch { Start-Sleep -Milliseconds 100 }
    }

    # Create + walk a task to in-progress.
    $r = Invoke-Raw -Url $start.url -Method POST -Path '/tasks' -Token $start.token -Body @{ name = 'hooktest'; actor = 'test:ci' }
    $tid = $r.body.task.id

    $r = Invoke-Raw -Url $start.url -Method POST -Path "/tasks/$tid/status" -Token $start.token -Body @{ to = 'in-progress'; actor = 'test:ci' }
    Assert-Equal -Name "todo → in-progress → 200" -Expected 200 -Actual $r.status_code

    # Now attempt in-progress → done; the aborting hook should reject it.
    $r = Invoke-Raw -Url $start.url -Method POST -Path "/tasks/$tid/status" -Token $start.token -Body @{ to = 'done'; actor = 'test:ci' }
    Assert-Equal -Name "Aborting hook → 422 hook_aborted"           -Expected 422 -Actual $r.status_code
    Assert-Equal -Name "Response error code is hook_aborted"        -Expected 'hook_aborted' -Actual $r.body.error
    Assert-Equal -Name "Response names the failing hook"            -Expected 'enter-done' -Actual $r.body.failing_hook
    Assert-True  -Name "Response carries failing_message"           -Condition ($r.body.failing_message -match 'verify says no')
    Assert-Equal -Name "Response reverted_to = in-progress"         -Expected 'in-progress' -Actual $r.body.reverted_to

    # Disk state: task is back to in-progress.
    $r = Invoke-Raw -Url $start.url -Method GET -Path "/tasks/$tid" -Token $start.token
    Assert-Equal -Name "After abort: GET returns 200"               -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "After abort: status reverted to in-progress" -Expected 'in-progress' -Actual $r.body.task.status

    # #571: a done-transition abort leaves a breadcrumb under extensions.runner so
    # the task-runner can escalate to needs-input instead of burning retries.
    $blockAfterAbort = $null
    try { $blockAfterAbort = $r.body.task.extensions.runner.done_transition_block } catch { $blockAfterAbort = $null }
    Assert-True  -Name "#571 After abort: done_transition_block marker present" `
        -Condition ($null -ne $blockAfterAbort) `
        -Message "Expected extensions.runner.done_transition_block, got task: $($r.body.task | ConvertTo-Json -Depth 8 -Compress)"
    Assert-Equal -Name "#571 After abort: marker names the failing hook" -Expected 'enter-done' -Actual "$($blockAfterAbort.hook)"
    Assert-True  -Name "#571 After abort: marker carries the failing message" `
        -Condition ("$($blockAfterAbort.message)" -match 'verify says no')

    # Activity log carries hook_failed.
    $logPath = Get-ActivityLogPath -BotRoot $bot
    $hookFailedLines = 0
    Get-Content -LiteralPath $logPath | ForEach-Object {
        try {
            $obj = $_ | ConvertFrom-Json -ErrorAction Stop
            if ($obj.type -eq 'hook_failed' -and $obj.task_id -eq $tid) { $hookFailedLines++ }
        } catch { }
    }
    Assert-True -Name "activity.jsonl contains hook_failed for the task" -Condition ($hookFailedLines -ge 1)

    # Replace the aborter with an advisory hook; transition should now succeed.
    Remove-Item -LiteralPath (Join-Path $projectHookDir 'enter-done') -Recurse -Force
    New-HookFixture -Root $projectHookDir -Name 'enter-done' -Targets 'done' -AbortOnFailure $false `
        -ScriptBody '@{ Success = $true; Message = "advisory ok"; Duration = [TimeSpan]::Zero }'

    $r = Invoke-Raw -Url $start.url -Method POST -Path "/tasks/$tid/status" -Token $start.token -Body @{ to = 'done'; actor = 'test:ci' }
    Assert-Equal -Name "With non-aborting hook: in-progress → done → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "Task status now done"                              -Expected 'done' -Actual $r.body.task.status
    Assert-True  -Name "Response includes hook_results"                    -Condition ($r.body.hook_results.Count -ge 1)

    # #571: a successful transition clears the stale hook-block breadcrumb.
    $blockAfterDone = $null
    try { $blockAfterDone = $r.body.task.extensions.runner.done_transition_block } catch { $blockAfterDone = $null }
    Assert-True -Name "#571 After successful done: done_transition_block marker cleared" `
        -Condition ($null -eq $blockAfterDone) `
        -Message "Expected marker cleared, got: $($blockAfterDone | ConvertTo-Json -Compress)"
} finally {
    if ($start) { Stop-DotbotRuntime -BotRoot $bot -Listener $start.listener -ErrorAction SilentlyContinue }
    try { Remove-Item -Recurse -Force (Split-Path -Parent $bot) } catch { }
}

Write-TestSummary -LayerName "Hooks"

if ((Get-TestResults).Failed -gt 0) { exit 1 } else { exit 0 }
