# PRD-12: Workflow runtime semantics

## Problem Statement

As a developer starting a workflow, I want a precise contract for what happens between my click and the first task running. Today PRD-04 says `POST /workflows/runs` "materializes task instances" and PRD-01 says a WorkflowRun completes when all required tasks are done — but no PRD spells out the expansion logic, when aggregation fires, or what happens to in-flight tasks if I cancel a run mid-flight.

## Solution

Define the three runtime behaviours that bind workflows to tasks: **expansion** (manifest → TaskInstances), **status aggregation** (task transitions → WorkflowRun status), and **cancellation cascade** (WorkflowRun cancellation → in-flight tasks). All three are owned by `Dotbot.Workflow`. Each fires at a specific point in the lifecycle; each has a deterministic outcome.

## User Stories

1. As a developer starting `start-from-repo`, I want the runtime to parse `workflow.yaml`, evaluate the project's state against the workflow's preconditions, and materialize one TaskInstance per TaskDefinition, so that one HTTP call kicks off the whole run.
2. As a developer with multiple `form.modes` on a workflow, I want the runtime to pick the right mode based on filesystem checks (e.g. "mission.md exists" vs "no mission.md"), so that the workflow knows whether it's a first run or a re-run.
3. As a developer with a workflow that has a `mode` argument override, I want that override to be honored, so that I can force a specific mode without relying on auto-detection.
4. As a developer whose workflow expansion fails (bad workflow.yaml, missing dependency, etc.), I want the WorkflowRun never created and a clear error returned, so that I don't end up with a half-materialized run.
5. As a developer with tasks that have `depends_on` entries by name, I want the expander to resolve those names into TaskInstance IDs at materialization, so that the runtime can schedule them correctly.
6. As a developer marking a task `done`, I want the runtime to check whether the parent WorkflowRun is now complete, so that the run transitions to `completed` without me triggering anything.
7. As a developer marking a task `failed`, I want the runtime to check whether the failure is a required task, so that the parent WorkflowRun goes to `failed` if so.
8. As a developer with optional tasks in my workflow, I want their `skipped` or `failed` status to NOT block the run's completion, so that the run finishes when the required work is done.
9. As a developer cancelling a workflow run mid-flight, I want the runtime to terminate child processes for that run, so that no AI keeps writing files after my click.
10. As a developer cancelling a workflow run, I want any in-progress tasks marked `failed` with a `reason: "cancelled by parent run <id>"`, so that the task records reflect what happened.
11. As a developer cancelling a workflow run, I want any uncommitted work in the worktree captured as a `wip:` commit, so that I can inspect what was done before cancellation.
12. As a developer inspecting a completed run's `run.json`, I want to see the resolved task definitions (post-expansion), so that I can audit exactly what was scheduled.

## Implementation Decisions

`Dotbot.Workflow` owns three named operations: `Expand-WorkflowRun`, `Update-WorkflowRunStatus`, `Cancel-WorkflowRun`. They are called by the runtime at precise lifecycle moments.

**Expansion (`Expand-WorkflowRun`):**
1. Resolve the workflow's `workflow.yaml` path (PRD-13 covers resolution).
2. Parse the manifest into a TaskDefinition list and the workflow's `isolated` flag.
3. If the caller passed an explicit `mode`, select that mode from `form.modes`. Otherwise evaluate each mode's `condition` (filesystem checks like `path-exists`, `!path-exists`) against the project root and pick the first satisfied mode. If none match, abort with a clear error.
4. Validate preconditions (`requires.cli_tools`, `requires.mcp_servers`). Failure → abort.
5. Generate a new `run_id` (`wr_` + 8-char nanoid).
6. For each TaskDefinition: generate a `t_<id>`; resolve `depends_on` (which is by name in YAML) into a list of TaskInstance IDs by looking up other definitions in the same run; create a TaskInstance with provenance `{ workflow, run_id, definition_name, expanded_by: "workflow-expansion" }`.
7. If isolated: create the worktree (PRD-03) before writing any task files; place the run directory under the worktree at `workspace/tasks/workflow-runs/<dir>/`. If not isolated: place it directly under the project's `workspace/tasks/workflow-runs/<dir>/`.
8. Write `run.json` (the committed provenance record per PRD-01) and one `t_<id>.json` per task.
9. Write the gitignored live-status record at `.control/workflow-runs/<wr_id>.json` with `status: running`.
10. Return the WorkflowRun record.

Expansion is **atomic from the caller's perspective**: either every artifact is created or none is. On any failure, partial artifacts are removed before the error is returned.

**Status aggregation (`Update-WorkflowRunStatus`):**

Fires from a transition hook installed on every terminal task transition (`enter-done`, `enter-failed`, `enter-skipped`). The hook calls `Update-WorkflowRunStatus -RunId $parentRunId`.

Logic:
- Load all tasks belonging to the run (from `run.json`'s task ID list).
- If any required task is in `failed`: WorkflowRun → `failed`.
- Else if every required task is in `done | skipped`: WorkflowRun → `completed`.
- Else: WorkflowRun stays `running`.

The aggregation runs inside the WorkflowRun mutex (PRD-04) to avoid races between two terminal tasks completing simultaneously.

When the WorkflowRun reaches a terminal status, additional side effects fire:
- Worktree cleanup (PRD-03's `Complete-WorkflowRunWorktree -Reason completed|failed`).
- `completed_at` is stamped on the run record.
- An event is emitted to `.control/activity.jsonl` (per PRD-04's expanded scope).

**Cancellation cascade (`Cancel-WorkflowRun`):**

Triggered by an explicit caller (UI button, CLI). Logic:
1. Acquire the WorkflowRun mutex.
2. For each child process tracked under this run (via `Dotbot.Process`): signal termination; wait the grace period (default 30s); force-kill on timeout.
3. For each task in the run not already in a terminal state (`done`, `failed`, `skipped`, `cancelled`): transition to `cancelled` with `reason: "cancelled by parent run <id>"`. The transition fires its normal hooks (`enter-cancelled`), so audit-log entries land.
4. Call PRD-03's worktree cleanup with `-Reason cancelled` (captures wip commit on branch, removes worktree directory).
5. Mark the WorkflowRun status as `cancelled` (direct transition from `running`; no intermediate state).

The cascade is **best-effort but observable**: every child task either ends in a terminal state with a clear reason, or the runtime logs a hard failure that's surfaced via the activity log.

## Testing Decisions

A good test for this PRD drives the public functions (`Expand-WorkflowRun`, `Update-WorkflowRunStatus`, `Cancel-WorkflowRun`) against fixture workflows + tmp projects, and asserts on the resulting state (task files on disk, WorkflowRun record content, child process termination).

Modules to be tested:
- **Dotbot.Workflow** (expansion) — happy path: manifest parses; mode auto-selects; task IDs allocated; depends_on resolved; files written. Failure paths: bad manifest aborts with no artifacts; no mode matches aborts; partial-failure mid-write rolls back.
- **Dotbot.Workflow** (aggregation) — required-tasks-all-done → completed; one required-task failed → failed; optional-task skipped is ignored; aggregation under mutex (concurrent terminal transitions don't double-fire).
- **Dotbot.Workflow** (cancellation) — child processes signaled; in-progress tasks transitioned to failed with reason; worktree cleanup invoked with `cancelled`; already-terminal tasks untouched.

Prior art: `tests/Test-WorkflowIntegration.ps1` (if present on v4) is the closest pattern. Reuse the tmp-project setup. Mock child processes by spawning a sleep job that observes the termination signal.

## Out of Scope

- Form-mode condition syntax — keep today's syntax (`path-exists`, `!path-exists` plus a small set). Adding richer condition expressions is a follow-up.
- Workflow-of-one expansion for standalone tasks — already implicit in PRD-02 (standalone uses the same machinery with a single task). Document briefly here; no separate expansion path.
- Cross-workflow dependencies — a task in workflow A depending on a task in workflow B. Not supported; depends_on only resolves within the same run.
- Re-run with task reuse — re-running a workflow always produces fresh tasks per PRD-02 (`Always create fresh tasks` was the locked decision). No "adopt orphans" mode.
- Workflow timeouts (entire workflow > N hours → auto-cancel) — not in scope; manual cancel is the only path.

## Further Notes

- Aggregation fires from a transition hook (PRD-06's `enter-done`, `enter-failed`, `enter-skipped`, `enter-cancelled`). The hook is part of this PRD's scope conceptually but is registered as a hook plugin so it's discoverable.
- Cancellation grace period (30s) is the same as PRD-03's worktree cancellation. Document once; reference from both.
- WorkflowRun status transitions directly `running → cancelled` after the cascade completes. There is no intermediate state — the transition is atomic from the caller's perspective.
- Open question for implementor: should aggregation also fire on `enter-needs-input` (the run pauses) so the UI can show "waiting for human" prominently? Proposal: the run stays `running` while a task is in needs-input; UI derives "waiting on input" from the current_task field, not a WorkflowRun status.
