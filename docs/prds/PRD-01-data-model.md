# PRD-01: Canonical data model

## Problem Statement

As a developer using dotbot, when I create or query tasks I want a predictable shape, a clear status lifecycle, and an on-disk layout that lets me see at a glance what work happened when. Today the shape of a task is implicit (it varies across modules), the status enum has redundant or confusing states, and tasks live in per-status folders that don't reflect time, workflow origin, or run.

## Solution

Define TaskInstance, TaskDefinition, and WorkflowRun as canonical, validated shapes inside the `Dotbot.Task` and `Dotbot.Workflow` modules. Adopt a forward-only status lifecycle with explicit named recovery transitions (no permissive any-to-any moves). Reorganise on-disk task storage so workflow runs are date-prefixed directories and standalone tasks are date-prefixed single files. Ship a schema_version field so future evolution is explicit.

## User Stories

1. As a developer, I want every task on disk to declare a schema_version, so that I can tell which schema is in use without sniffing fields.
2. As a developer, I want a task's required fields to be validated on write, so that malformed tasks are rejected at the source rather than discovered later.
3. As a developer, I want unknown top-level fields on a task to be rejected, so that typos in field names don't silently create new fields.
4. As a developer, I want to attach custom data under a namespaced `extensions` object, so that I can evolve workflow-specific data without polluting the core schema.
5. As a developer, I want every task to record its origin (workflow, run, definition entry), so that I can answer "what tasks did this run produce?" definitively.
6. As a developer, I want standalone tasks to have null provenance, so that "ad-hoc" is distinguishable from "spawned by a workflow".
7. As a developer browsing `ls`, I want directories named with a date prefix, so that listing them gives me a chronological view of work.
8. As a developer, I want each workflow run to be a single self-contained directory on disk, so that I can `cat`, `git log`, or archive a run as one unit.
9. As a developer, I want standalone tasks stored as single files rather than directories, so that the layout reflects that they're not a multi-task unit.
10. As a developer, I want task IDs to be short and stable (`t_AbCd1234`), so that I can refer to them in chat and logs without retyping a long UUID.
11. As a developer, I want directory and filenames to use a 4-character prefix of the canonical ID, so that names stay short while still disambiguating same-day same-workflow collisions.
12. As a developer marking a task done, I want only legal transitions to be accepted (e.g. `analysed → in-progress → done`), so that the state machine catches mistakes before side effects fire.
13. As a developer who clicked the wrong status, I want a named recovery transition (`done → todo` reopen), so that I can fix mistakes without surgical edits to JSON.
14. As a developer running a long task, I want `in-progress → analysed` (kick-back), so that I can return work to analysis when the plan is wrong.
15. As a developer, I want a single forward sequence to learn (`todo → analysing → analysed → in-progress → done`), so that the mental model is small.
16. As a developer reviewing a failed task, I want `failed` and `skipped` as terminal statuses distinct from `done`, so that I can tell what kind of "stopped" a task is in.
17. As a developer resuming after asking for input, I want `needs-input → analysing` as a clean resume edge, so that human-in-the-loop pauses have an obvious return path.
18. As a developer of a workflow, I want a WorkflowRun's immutable provenance (workflow name, started_at, materialised task IDs, branch, worktree path) to be committed alongside the tasks, so that the run's identity travels with the repo.
19. As a developer, I want the WorkflowRun's churning live status (running/heartbeat/current task) kept out of git, so that committing the run record doesn't churn on every state change.
20. As a developer running `git log` against an old run's directory, I want to see exactly what tasks the run produced and how they ended, so that I can audit a past run without spelunking through the runtime.

## Implementation Decisions

The TaskInstance shape is closed: a fixed set of core fields (`id`, `name`, `description`, `status`, `provenance`, `category`, `priority`, `effort`, `type`, `dependencies`, `acceptance_criteria`, `outputs`, `created_at`, `updated_at`, `completed_at`, `updated_by`, `schema_version`, `extensions`). Unknown top-level fields raise a validation error. All non-namespaced custom data must live under `extensions.<namespace>`.

The TaskInstance schema, encoded in `Dotbot.Task`, is the authority. Every reader and writer goes through it:

```jsonc
{
  "schema_version": 2,
  "id": "t_AbCd1234",
  "status": "todo",
  "provenance": {
    "workflow": "implement-feature" | null,
    "run_id": "wr_EfGh5678" | null,
    "definition_name": "Form UI" | null,
    "expanded_by": null | "workflow-expansion" | "task:t_<id>"
  },
  ...,
  "extensions": { "workflow.implement-feature": { "phase": 1 } }
}
```

The status enum is exactly: `todo`, `analysing`, `analysed`, `in-progress`, `done`, `failed`, `skipped`, `cancelled`, `needs-input`. The v4 status `split` is dropped entirely (humans resolve splits by closing the parent and creating children). `cancelled` is a **terminal** task status set by the cancellation cascade (PRD-12) when a parent WorkflowRun is cancelled; no recovery from `cancelled` (to retry, create a new task).

The transition table is enforced as a closed map. Forward edges, sideways edges (pause/fail), and named recovery edges are explicitly listed; all other transitions throw. The table is owned by `Dotbot.Task` and exposed as `Test-TaskTransition`, `Get-AllowedTransitions`, `Assert-TaskTransition`.

```
todo         → analysing | skipped | cancelled
analysing    → analysed  | needs-input | failed | cancelled
analysed     → in-progress | needs-input | skipped | cancelled
in-progress  → done | needs-input | failed | analysed | cancelled   # 'analysed' = kick-back
needs-input  → analysing | cancelled                              # resume or cancel
done         → todo                                              # reopen
failed       → todo                                              # retry
skipped      → todo                                              # unskip
cancelled    → (terminal — no recovery)
```

IDs use a nanoid alphabet `[A-Za-z0-9]`. Task IDs are `t_` + 8 chars; WorkflowRun IDs are `wr_` + 8 chars. Directory and filename short forms are the 4-char prefix of the canonical (`AbCd`); the canonical full ID stays in JSON. The 4-char form is derived, never separately allocated.

On-disk layout under each project:
- Committed under `workspace/tasks/workflow-runs/<YYYY-MM-DD>-<workflow-slug>-<4char>/` per run, containing `run.json` and one `t_<id>.json` per task in the run.
- Committed under `workspace/tasks/standalone/<YYYY-MM-DD>-<task-slug>-<4char>.json` per standalone task.
- Gitignored under `.control/workflow-runs/<wr_id>.json` for live status.

The committed run record (`run.json`) holds immutable provenance: `run_id`, `workflow_name`, `started_at`, `isolated`, `branch_name`, `worktree_path`, the materialised task IDs, the resolved task definitions, and the `started_by` actor. The gitignored live-status record holds `status`, `completed_at`, `last_heartbeat`, `current_task_id`, and error details when applicable.

TaskDefinition (workflow.yaml entry) keeps `name`, `type`, `depends_on`, `prompt`, `outputs`, `priority`, `optional`. The v4-current fields `skip_worktree`, `working_dir`, `external_repo`, `commit`, `front_matter_docs`, `post_script` are removed from the schema. (`post_script` becomes a transition hook concern in PRD-06.)

WorkflowRun has its own `schema_version` (=1 for first release) so its evolution is independent of TaskInstance's.

This PRD does not introduce any migration tooling — the rewrite assumes greenfield projects. Legacy v1 layouts are not supported.

## Testing Decisions

A good test for this module asserts on **external behaviour**: given an input record, does validation accept or reject it? Given a from/to pair, does the transition table accept or reject it? Tests should not poke at internal helpers; they should call the module's public surface and assert on the result or the thrown exception.

Modules to be tested:
- **Dotbot.Task** (schema + transitions + layout + IdGen) — every required field, every forbidden field, every legal transition, every illegal transition, the `extensions` namespace roundtrip, the layout function's path derivation.
- **Dotbot.Workflow** (WorkflowRun + TaskDefinition schemas) — same shape of validation tests against the WorkflowRun and TaskDefinition records.

Prior art: the existing `tests/Test-WorkflowManifest.ps1` is the closest pattern — Pester-style assertions against a parsed shape. Extend that style. The atomic file-write tests under `tests/Test-Components.ps1` for `TaskFile.psm1` are a useful precedent for testing serialization roundtrips.

## Out of Scope

- Concurrency enforcement of who-can-mutate-when (PRD-02 owns the rules; PRD-04 enforces).
- Worktree mechanics (PRD-03).
- The HTTP API that exposes these records (PRD-04).
- Plugin executor dispatch on task `type` (PRD-05).
- Transition side-effects / hook invocation (PRD-06).
- Migration of pre-existing data: deliberately not supported.

## Further Notes

- The `outputs` field on TaskInstance is optional; on TaskDefinition it's optional but encouraged for downstream verification.
- For tasks spawned mid-run by another task (`expanded_by: "task:t_xxxxxxxx"`), the directory date is the parent run's `started_at` date, not the child task's `created_at`.
- Open question for implementor: do we add a `tags` array on TaskInstance? Not in this PRD's scope; add later if a consumer needs it.
- The `extensions` namespace convention should follow dotted names: `workflow.<name>`, `executor.<name>`, `ui`, `user`. Conflicts are the caller's responsibility.
