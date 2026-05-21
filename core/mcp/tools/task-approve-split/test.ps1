Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# Test task-approve-split tool. Issue-#25 regression guard: this file is
# dot-sourced from core/ui/modules/TaskAPI.psm1:487. Strict-mode directives
# must live inside the function body, not at file top.

Import-Module $env:DOTBOT_TEST_HELPERS -Force

# Dot-source isolation probe.
Set-StrictMode -Off
$probe = [pscustomobject]@{ a = 1 }
$beforeOk = $true
try { $null = $probe.b } catch { $beforeOk = $false }

. "$PSScriptRoot\script.ps1"

$afterOk = $true
try { $null = $probe.b } catch { $afterOk = $false }

Set-StrictMode -Version 3.0

Reset-TestResults

Assert-True -Name "task-approve-split: caller starts in strict-off (sanity)" -Condition $beforeOk
Assert-True -Name "task-approve-split: dot-sourcing does not elevate caller's strict mode" `
    -Condition $afterOk -Message "Strict mode must be inside the function body. See issue #25."

# Functional: missing task_id should throw at the guard clause.
$missingTaskOk = $false
try {
    Invoke-TaskApproveSplit -Arguments @{ approved = $true } | Out-Null
} catch {
    $missingTaskOk = $_.Exception.Message -match 'Task ID is required'
}
Assert-True -Name "task-approve-split: throws when task_id is omitted" -Condition $missingTaskOk

# Functional: missing approved flag should throw at the guard clause.
$missingApprovedOk = $false
try {
    Invoke-TaskApproveSplit -Arguments @{ task_id = 'nonexistent-task-xyz' } | Out-Null
} catch {
    $missingApprovedOk = $_.Exception.Message -match 'Approved flag'
}
Assert-True -Name "task-approve-split: throws when approved flag is omitted" -Condition $missingApprovedOk

# Functional: non-existent task with valid flag set throws with descriptive message.
$notFoundOk = $false
try {
    Invoke-TaskApproveSplit -Arguments @{ task_id = 'nonexistent-task-xyz'; approved = $true } | Out-Null
} catch {
    $notFoundOk = $_.Exception.Message -match 'not found'
}
Assert-True -Name "task-approve-split: throws with 'not found' for missing task" -Condition $notFoundOk

$allPassed = Write-TestSummary -LayerName "task-approve-split"
if (-not $allPassed) { exit 1 }
