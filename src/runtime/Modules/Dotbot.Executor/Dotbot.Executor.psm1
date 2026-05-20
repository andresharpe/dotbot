<#
.SYNOPSIS
Dotbot.Executor entry module — plugin executor discovery + dispatch.

Canonical PRD: docs/prds/PRD-05-executors.md.

A task with `type: foo` is dispatched to the executor folder whose
metadata.yaml declares `task_type: foo`. Adding a new type is a matter of
dropping a folder under src/runtime/executors/; no edits to the core
dispatch are required.

The actual implementation is split across nested modules under v4/:
  - Discovery.psm1 — scan folder, parse metadata.yaml, validate, index by task_type.
  - Dispatch.psm1  — required-field check, runspace invocation, timeout enforcement.
#>

$script:ExecutorModuleRoot = $PSScriptRoot

# Nothing to export from the root file itself — the v4/*.psm1 children each
# export their own public surface, and the manifest's FunctionsToExport pins
# what callers see.
