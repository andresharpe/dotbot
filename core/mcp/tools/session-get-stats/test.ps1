Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# Test session-get-stats tool. Issue-#25 regression guard: this file is
# dot-sourced by core/ui/modules/StateBuilder.psm1 (Get-BotState lines 63-64).
# Strict-mode directives must live inside the function body.

Import-Module $env:DOTBOT_TEST_HELPERS -Force

# Probe BEFORE/AFTER dot-source for strict-mode isolation.
Set-StrictMode -Off
$probe = [pscustomobject]@{ a = 1 }
$beforeOk = $true
try { $null = $probe.b } catch { $beforeOk = $false }

. "$PSScriptRoot\script.ps1"

$afterOk = $true
try { $null = $probe.b } catch { $afterOk = $false }

Set-StrictMode -Version 3.0

Reset-TestResults

Assert-True -Name "session-get-stats: caller starts in strict-off (sanity)" -Condition $beforeOk
Assert-True -Name "session-get-stats: dot-sourcing does not elevate caller's strict mode" `
    -Condition $afterOk -Message "Strict mode must be inside the function body. See issue #25."

# Functional: the function should return a hashtable with at least a `success`
# field whether or not a session exists.
$result = Invoke-SessionGetStats -Arguments @{}
Assert-True -Name "session-get-stats: returns a hashtable" -Condition ($null -ne $result)
Assert-True -Name "session-get-stats: response has a success field" `
    -Condition ($result -is [System.Collections.IDictionary] -and $result.ContainsKey('success'))

$allPassed = Write-TestSummary -LayerName "session-get-stats"
if (-not $allPassed) { exit 1 }
