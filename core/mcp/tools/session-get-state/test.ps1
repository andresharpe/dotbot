Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# Test session-get-state tool. Issue-#25 regression guard: this file is
# dot-sourced by core/ui/modules/StateBuilder.psm1 (Get-BotState lines 63-64).
# Its directives MUST live inside the function body, not at file top, or
# strict mode 3.0 will leak into Get-BotState's scope and trip latent
# unguarded property accesses (StateBuilder.psm1:604).

Import-Module $env:DOTBOT_TEST_HELPERS -Force

# Probe BEFORE dot-sourcing: confirm caller's strict-mode posture.
Set-StrictMode -Off
$probe = [pscustomobject]@{ a = 1 }
$strictOffBeforeDotSource = $true
try { $null = $probe.b } catch { $strictOffBeforeDotSource = $false }

. "$PSScriptRoot\script.ps1"

# Probe AFTER dot-sourcing: must still be strict-off if the file is isolated.
$strictOffAfterDotSource = $true
try { $null = $probe.b } catch { $strictOffAfterDotSource = $false }

# Restore strict mode for the rest of the test.
Set-StrictMode -Version 3.0

Reset-TestResults

Assert-True -Name "session-get-state: caller starts in strict-off (sanity)" `
    -Condition $strictOffBeforeDotSource

Assert-True -Name "session-get-state: dot-sourcing does not elevate caller's strict mode" `
    -Condition $strictOffAfterDotSource `
    -Message "Set-StrictMode -Version 3.0 must live inside the function body, not at file top. See issue #25."

# Functional checks — exercise the public function with a missing-session
# scenario (no Invoke-SessionInitialize beforehand). The function should
# return success=false with a descriptive error, not throw.
$cleanupPaths = @()
try {
    $result = Invoke-SessionGetState -Arguments @{}

    Assert-True -Name "session-get-state: returns success=false when no session exists" `
        -Condition ($result.success -eq $false)

    Assert-True -Name "session-get-state: returns descriptive error message" `
        -Condition ($null -ne $result.error -and $result.error.Length -gt 0) `
        -Message "Got: $($result.error)"

    # If a session file does exist (e.g. left over from a prior test), exercise
    # the success path too.
    $stateFile = Join-Path $global:DotbotProjectRoot ".bot\workspace\sessions\runs\session-state.json"
    if (Test-Path $stateFile) {
        $result2 = Invoke-SessionGetState -Arguments @{}
        Assert-True -Name "session-get-state: returns success=true with pre-existing session file" `
            -Condition ($result2.success -eq $true)
    }
} finally {
    foreach ($p in $cleanupPaths) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

$allPassed = Write-TestSummary -LayerName "session-get-state"
if (-not $allPassed) { exit 1 }
