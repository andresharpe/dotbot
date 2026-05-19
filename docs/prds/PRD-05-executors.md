# PRD-05: Plugin executors

## Problem Statement

As a developer, I want to add a new kind of task (e.g. one that calls an HTTP endpoint, performs a web search, or spawns another agent) without editing the core task module. Today the dispatch on task `type` is hard-coded inside `Dotbot.Task` and the workflow process loop, so adding a new type requires reaching into multiple files.

## Solution

Treat each task type as a **plugin executor** discovered from disk. Each executor is a folder containing a metadata declaration and a script that exports a single `Invoke-Executor` function. The core `Dotbot.Executor` module scans the executor directory at runtime startup, validates each executor's metadata, and dispatches by task `type`. Adding a new type is a matter of dropping a folder.

## User Stories

1. As a developer adding a new task type, I want to drop a folder containing `metadata.yaml` and `script.ps1`, so that the system picks it up without editing the core dispatch.
2. As a developer authoring an executor, I want a clear contract: a single exported function with a well-defined input shape (task + run context) and output shape (result), so that I don't have to reverse-engineer existing executors.
3. As a developer writing a task, I want to set `type: prompt` (or `script`, `mcp`) and have the right executor invoked, so that the task itself stays declarative.
4. As a developer authoring an executor, I want to declare `required_fields` in metadata, so that the dispatcher rejects tasks with missing fields before invoking my code.
5. As a developer authoring an executor, I want to declare `supports_worktree` and `supports_analysis` in metadata, so that the runtime can decide whether to run an analysis phase or set up a worktree before dispatching.
6. As a developer authoring an executor, I want to declare a maximum runtime duration, so that the runtime kills runaway executor processes without me writing watchdog code.
7. As a developer of the `prompt` executor, I want it to wrap the existing Claude harness launch logic, so that the bulk of the AI-spawning code doesn't have to be rewritten — just extracted into the executor folder.
8. As a developer of the `script` executor, I want it to run a PowerShell script declared on the task, so that workflows that mostly do orchestration don't need to invoke an AI.
9. As a developer of the `mcp` executor, I want it to call an MCP tool declared on the task with declared arguments, so that workflows can chain tool calls without an AI in the loop.
10. As a developer seeing an unknown `type` on a task, I want a clear error at dispatch time (not at parse time), so that I can fix the typo and move on.
11. As a developer running tests, I want executor discovery to be deterministic (same folder listing → same dispatcher state), so that I can write isolated tests against the dispatcher.

## Implementation Decisions

Executors live under a stable directory, one folder per executor:

```
runtime/executors/
  prompt/
    metadata.yaml
    script.ps1
  script/
    metadata.yaml
    script.ps1
  mcp/
    metadata.yaml
    script.ps1
```

Each `metadata.yaml`:

```yaml
name: prompt
task_type: prompt
description: "Spawn the Claude harness with a prompt template."
required_fields:
  - name
  - description
optional_fields:
  - prompt
  - acceptance_criteria
supports_worktree: true
supports_analysis: true
max_executor_duration: 7200
```

Each `script.ps1` exports a single function:

```powershell
function Invoke-Executor {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )
    # Returns @{ Success = $true|$false; Message = "..."; ExitCode = N }
}
Export-ModuleMember -Function Invoke-Executor
```

`RunContext` carries the WorkflowRun record (id, isolated, worktree_path, project_root) plus a `RuntimeClient` reference the executor can call back into for further state mutations.

`Dotbot.Executor` scans the executors directory at runtime startup, parses each `metadata.yaml`, indexes by `task_type`. Discovery is reproducible: a folder either parses correctly and is registered, or fails registration with a clear startup error.

Dispatch flow:
1. Caller requests execution of a task.
2. `Dotbot.Executor.Invoke-TaskExecutor` looks up the executor by `task.type`. Missing → throws `UnknownTaskType`.
3. Validates `required_fields` against the task. Missing field → throws `MissingExecutorField`.
4. Invokes the executor's `Invoke-Executor` in a child runspace (so the runtime stays responsive). Enforces `max_executor_duration`; on timeout the runspace is forcibly stopped and a failure result returned.
5. Returns the executor's result to the caller.

The three initial executors:
- **prompt** — thin shim around the existing Claude-harness launch logic. The executor extracts the prompt-build / worktree-ensure / harness-spawn sequence from `Invoke-WorkflowProcess.ps1`; the original orchestration code is removed.
- **script** — runs a PowerShell script whose path is declared on the task. Captures stdout/stderr; returns success based on exit code.
- **mcp** — calls an MCP tool declared on the task with the declared arguments via the runtime's tool dispatch. Useful for workflows that orchestrate other workflows or call non-AI tools.

**Process tracking.** Executors that spawn child processes (currently `prompt` and `script`) register them with `Dotbot.Process` so the runtime can track and signal them later (e.g. cascade cancellation in PRD-12). `Dotbot.Process` keeps its existing public surface (registry under `<project>/.bot/.control/processes/`) — this PRD does not rewrite it, only ensures executors call into it consistently rather than each rolling their own tracking.

This PRD owns the executor contract and the dispatcher. The hook plugin pattern (which is structurally similar) lives in a separate module — `Dotbot.Hook` (PRD-06).

## Testing Decisions

A good test for this module asserts on external behaviour: given a fixture directory of executors and a task, does the dispatcher route correctly? Tests should not assert on the executor's internal logic — only on the dispatcher's contract.

Modules to be tested:
- **Dotbot.Executor** (discovery) — fixture directory with three valid executors + one malformed → three registered, malformed produces a startup error.
- **Dotbot.Executor** (dispatch) — task with known type → correct executor invoked; unknown type → `UnknownTaskType`; missing required field → `MissingExecutorField`.
- **Dotbot.Executor** (timeout) — fixture executor with `max_executor_duration: 1` that sleeps for 5 → dispatcher kills it and returns failure within bounded time.
- Each shipped executor (prompt/script/mcp) — round-trip tests with a minimal task that exercises the contract surface, not the executor's downstream effects (those are integration concerns).

Prior art: the MCP tool auto-discovery pattern in `src/mcp/server.ps1` is the closest analogue. Reuse the same scan-folder-parse-metadata approach. Test setup uses tmp directories to seed executor fixtures.

## Out of Scope

- The data model and `type` field validation: PRD-01.
- Transition hooks (the parallel plugin pattern for status-change side effects): PRD-06.
- The HTTP runtime that triggers execution: PRD-04.
- Logging, telemetry, or instrumentation of executor runs: handled by the runtime, not the executor module.
- Sandboxing or permissioning of executor scripts: trust the task author for now.

## Further Notes

- The three initial executors are sufficient for current workflows. New executors (e.g. `http_call`, `web_search`, `agent_spawn`) drop in as future PRDs.
- The `prompt` executor's extraction from `Invoke-WorkflowProcess.ps1` should be mechanical — move the existing logic, don't rewrite it. The win is the seam, not the implementation.
- **Open question for implementor: `Dotbot.Process` is kept intact** with its existing surface (registry at `<project>/.bot/.control/processes/`). This PRD assumes executors call into it consistently for process tracking but doesn't rewrite the module. Confirm the assumption — if the module needs material reshape (e.g. to register processes with run_id provenance for the cancellation cascade), raise a follow-up.
- Open question for implementor: should executors be allowed to call back into the runtime to create new tasks (i.e. `task_gen` style expansion)? Proposal: yes, via the `RuntimeClient` in `RunContext`. The `expanded_by: "task:t_xxxxxxxx"` provenance field exists precisely for this case.
