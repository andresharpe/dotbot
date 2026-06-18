<#
.SYNOPSIS
Dotbot.Runtime entry module — per-project HTTP runtime owning mutexes,
state transitions, and activity-log emission.

This file imports the sibling modules Dotbot.Task and Dotbot.Workflow (the
schema + transition + isolation rules live there) so callers only need
`Import-Module Dotbot.Runtime` to get the whole HTTP surface.

The actual implementation is split across nested modules under Private/:
  - EndpointDiscovery.psm1 — env > settings > .control/runtime.json
  - Mutex.psm1             — per-task / per-run SemaphoreSlim pool
  - ActivityLog.psm1       — atomic single-line append to activity.jsonl
  - Lifecycle.psm1         — start/stale-PID detect/shutdown
  - HttpServer.psm1        — listener loop, auth, routing, handlers
  - Client.psm1            — Invoke-RuntimeRequest helper used by MCP + UI

Required manifest dependencies: Dotbot.Task, Dotbot.Workflow, Dotbot.Hook,
Dotbot.Settings. Dotbot.Runtime.psd1 loads them before this root file so the
private modules can assume their exported commands are already present.
#>

# Nothing to export from the root file itself — the Private/*.psm1 children
# each export their own public surface, and the manifest's
# FunctionsToExport pins what callers see.
