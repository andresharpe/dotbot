<#
.SYNOPSIS
Dotbot.Executor entry module — plugin executor discovery + dispatch.

A task with `type: foo` is dispatched to the executor folder whose
metadata.json declares `task_type: foo`. Adding a new type is a matter of
dropping a folder under src/runtime/Plugins/Executors/; no edits to the core
dispatch are required.

The implementation is split across nested modules under Private/:
  - Discovery.psm1 — scan folder, parse metadata.json, validate, index by task_type.
  - Dispatch.psm1  — required-field check, runspace invocation, timeout enforcement.
#>

$script:ExecutorModuleRoot = $PSScriptRoot

# The nested modules export their own public surface; the manifest's
# FunctionsToExport pins what callers see.
