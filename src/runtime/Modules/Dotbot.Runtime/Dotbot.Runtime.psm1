<#
.SYNOPSIS
Dotbot.Runtime entry module — per-project HTTP runtime owning mutexes,
state transitions, and activity-log emission.

This file imports the sibling modules Dotbot.Task and Dotbot.Workflow (the
schema + transition + isolation rules live there) so callers only need
`Import-Module Dotbot.Runtime` to get the whole HTTP surface.

The actual implementation is split across nested modules under internal/:
  - EndpointDiscovery.psm1 — env > settings > .control/runtime.json
  - Mutex.psm1             — per-task / per-run SemaphoreSlim pool
  - ActivityLog.psm1       — atomic single-line append to activity.jsonl
  - Lifecycle.psm1         — start/stale-PID detect/shutdown
  - HttpServer.psm1        — listener loop, auth, routing, handlers
  - Client.psm1            — Invoke-RuntimeRequest helper used by MCP + UI
#>

# Sibling-module imports. Dotbot.Task brings IdGen / Transitions /
# TaskInstance / Layout into scope. Dotbot.Workflow brings WorkflowRun /
# TaskDefinition / Test-CanStartRun / Test-GitReadyForIsolation. The
# Get-Module idempotency guard mirrors the rest of the runtime: avoids
# reloading into a private scope and nuking a global instance.
$script:RuntimeModuleRoot = $PSScriptRoot

if (-not (Get-Module Dotbot.Task)) {
    $taskPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'Dotbot.Task' 'Dotbot.Task.psd1'
    Import-Module $taskPsd1 -DisableNameChecking -Global
}
if (-not (Get-Module Dotbot.Workflow)) {
    $wfPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'Dotbot.Workflow' 'Dotbot.Workflow.psd1'
    Import-Module $wfPsd1 -DisableNameChecking -Global
}
# Dotbot.Hook brings Invoke-TransitionHooks + discovery into scope so the
# task-status handler can fire registered hooks inline with Set-TaskStatus.
# Mirrors the Task/Workflow import pattern above.
if (-not (Get-Module Dotbot.Hook)) {
    $hookPsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'Dotbot.Hook' 'Dotbot.Hook.psd1'
    Import-Module $hookPsd1 -DisableNameChecking -Global
}

# Nothing to export from the root file itself — the internal/*.psm1 children
# each export their own public surface, and the manifest's
# FunctionsToExport pins what callers see.
