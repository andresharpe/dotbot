# PRD-06: Plugin transition hooks

## Problem Statement

As a developer, I want side effects that fire when a task changes status (verification on `done`, worktree ensure on `in-progress`, notification on `failed`) to live in their own files — not buried inside MCP tool scripts or hard-coded in the core. Today verification logic lives inside the `task-mark-done` MCP tool, and worktree setup is inline in the workflow process. Adding a new transition side effect means editing the wrong file.

## Solution

Treat each status-entry side effect as a **plugin hook** discovered from disk. Each hook is a folder containing `metadata.yaml` and `script.ps1`. The `Dotbot.Hook` module scans the hooks directory at runtime startup, indexes by target status, and invokes the relevant hooks synchronously during `Set-TaskStatus`. Hooks declare a maximum duration; the runtime enforces it. A failing hook with `abort_on_failure: true` reverts the transition.

## User Stories

1. As a developer, I want to add a side effect for a particular status change (e.g. `enter-done`) by dropping a folder, so that I don't edit the core state-machine code.
2. As a developer authoring a hook, I want a clear contract: a single exported function with the task, run context, and from/to status, so that I know exactly what's available.
3. As a developer whose hook can take time (verification scripts, commit-info extraction), I want to declare a maximum duration in metadata, so that runaway hooks are killed without me writing watchdog code.
4. As a developer relying on verification before a task is marked done, I want a failing hook to abort the transition, so that bad work doesn't slip into the done pile.
5. As a developer with a hook that's advisory (logging, notification), I want to declare `abort_on_failure: false`, so that the transition stands even if my hook errors.
6. As a developer marking a task `in-progress`, I want a hook to ensure the WorkflowRun's worktree exists (idempotently), so that the worktree is set up just-in-time rather than at workflow start.
7. As a developer marking a task `done`, I want the verification hook chain (gitleaks, framework integrity, etc.) to run before the status flips, so that broken work can't reach `done`.
8. As a developer marking a task `done`, I want commit info to be extracted into the task record, so that I can see which commits the task produced when I look at the JSON later.
9. As a developer marking a task `failed`, I want a hook to emit a notification and archive diagnostic state, so that I can investigate failures after the fact.
10. As a developer running concurrent transitions, I want hooks to run inside the task's mutex, so that a hook can't observe a half-applied transition.
11. As a developer reading hook results, I want hook duration and outcome logged, so that I can find slow hooks and tune them.
12. As a developer running tests, I want hook discovery to be deterministic, so that I can write isolated tests against the dispatcher.

## Implementation Decisions

Hooks live under a stable directory, one folder per hook:

```
runtime/Plugins/Hooks/Transitions/
  enter-in-progress/
    metadata.yaml
    script.ps1
  enter-done/
    metadata.yaml
    script.ps1
  enter-failed/
    metadata.yaml
    script.ps1
```

Each `metadata.yaml`:

```yaml
name: enter-done
description: "Verification + commit-info extraction + session close."
target_statuses: [done]
max_duration: 60
abort_on_failure: true
```

`target_statuses` allows a single hook to fire on entry to one or more statuses (e.g. an audit hook that fires on every terminal status).

Each `script.ps1` exports a single function:

```powershell
function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$FromStatus,
        [Parameter(Mandatory)][string]$ToStatus
    )
    # Returns @{ Success = $true|$false; Message = "..."; Duration = TimeSpan }
}
Export-ModuleMember -Function Invoke-Hook
```

`Dotbot.Hook` scans the hooks directory at runtime startup, parses metadata, indexes by `target_statuses`. Same discovery pattern as `Dotbot.Executor` (PRD-05) — but a separate module because the contract and use site differ.

Invocation pattern (consumed by `Dotbot.Task.Set-TaskStatus`):
1. After the transition table accepts the from/to pair and the new status is written to the task file (inside the task mutex from PRD-04):
2. `Dotbot.Hook.Invoke-TransitionHooks -ToStatus $To -Task $task -RunContext $ctx -FromStatus $From`.
3. For each matching hook, in declaration order: invoke in a child runspace with `max_duration` enforced. On timeout the runspace is forcibly stopped and the hook is marked failed.
4. If any hook with `abort_on_failure: true` returns failure (or times out): the new status is reverted (write back `FromStatus`); the failing hook's name + message is returned in the response to the caller of `POST /tasks/<id>/status`.
5. Hook outcome (success/failure, duration, message) is recorded in the audit log.

The shipped hooks:
- **enter-in-progress** — ensures the parent WorkflowRun's worktree exists (idempotent; no-op if isolated=false; calls `Dotbot.Worktree` from PRD-03). Registers the Claude session if a session ID is present in the environment.
- **enter-done** — runs the existing `.bot/hooks/verify/` chain (gitleaks, git-clean, md-refs, framework-integrity); extracts commit info via the existing helper; closes the Claude session. Aborts on any verification failure. Also fires WorkflowRun status aggregation (PRD-12).
- **enter-failed** — emits a notification through the existing notification channel; archives the task's last-known state into a diagnostic location for later inspection. Does not abort (the task is already failing). Fires WorkflowRun status aggregation.
- **enter-skipped** — fires WorkflowRun status aggregation. No other side effects.
- **enter-cancelled** — fires WorkflowRun status aggregation (in case a single task is cancelled directly outside a run cascade). No other side effects.

Hooks run **synchronously, inline with the `Set-TaskStatus` call**. The HTTP request `POST /tasks/<id>/status` blocks until all matching hooks complete. This is intentional — callers (UI, MCP) get a definitive result; hook latency is bounded by the declared `max_duration`.

This PRD does not introduce `exit-<status>` hooks (run before transition). All current side effects are entry side effects; the design preserves the option to add exits later if needed.

## Testing Decisions

A good test for this module operates against a fixture hooks directory and a stubbed task and asserts on observable behaviour: did the hook run, did it return failure, was the transition aborted, was the audit entry written.

Modules to be tested:
- **Dotbot.Hook** (discovery) — fixture directory with three valid hooks + one malformed → three registered, malformed produces a startup error.
- **Dotbot.Hook** (dispatch) — `Invoke-TransitionHooks -ToStatus done` invokes the `enter-done` hook(s); `-ToStatus skipped` invokes none if no hook targets it.
- **Dotbot.Hook** (timeout) — fixture hook with `max_duration: 1` that sleeps for 5 → dispatcher kills it; the failure is reported within bounded time.
- **Dotbot.Hook** (abort behaviour) — `abort_on_failure: true` hook returns failure → caller of `Invoke-TransitionHooks` is told to revert; `abort_on_failure: false` hook returns failure → caller is told to proceed.
- Each shipped hook (enter-in-progress / enter-done / enter-failed) — round-trip tests with a minimal task and run context; assert on the hook's externally observable outcome (verification ran, session closed, notification fired).

Prior art: the same scan-folder-parse-metadata pattern as `Dotbot.Executor` (PRD-05). Hook fixtures use tmp directories with throwaway `script.ps1` files that record their invocation for assertions.

## Out of Scope

- The state machine itself: PRD-01.
- The runtime that calls `Set-TaskStatus`: PRD-04.
- The executor plugin pattern (parallel concept, different module): PRD-05.
- `exit-<status>` hooks (before-transition): not in scope; revisit if a real need emerges.
- Cross-status hooks (one hook that fires on multiple from/to pairs with branching logic inside): not in scope; the model is "entry to a status" and that's it.

## Further Notes

- The synchronous execution model is deliberate. Asynchronous hooks would push callers (LLM, UI) into a polling protocol; staying synchronous keeps the API simple at the cost of bounded latency.
- Hook order within a status is the declaration order in the directory listing (alphabetical). Hooks should be independent; if a downstream hook depends on an upstream hook, name them `01-foo`, `02-bar` to make the ordering explicit.
- Open question for implementor: should hooks be allowed to mutate the task they fire on (e.g. `enter-done` writing commit info into task fields)? Proposal: yes, but only via the `RuntimeClient` in `RunContext` (PATCH `/tasks/<id>`), so audit + validation kick in. Don't allow direct file mutation from inside a hook.
