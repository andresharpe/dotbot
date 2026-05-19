# PRD-02: Workflow isolation + concurrency rules

## Problem Statement

As a developer, I want to control whether a workflow's work lands directly on my main checkout or in an isolated branch, and I want the system to be honest about which workflows can run at the same time. Today every prompt task gets its own worktree by default with a per-task `skip_worktree` escape hatch; whether two workflows can run simultaneously is implicit. The fragmented model makes it hard to reason about safety and parallelism.

## Solution

Make isolation a property of the **workflow run**, not the individual task. A workflow declares `isolated: true|false` at the top of `workflow.yaml`; all its tasks inherit. Standalone tasks are workflows-of-one with the same property (default isolated). Concurrency rules follow directly from isolation: isolated runs can coexist with anything; non-isolated runs are mutually exclusive because they share the main checkout.

## User Stories

1. As a developer, I want my workflow to declare its isolation policy once at the top of `workflow.yaml`, so that every task in it operates the same way.
2. As a developer, I want tasks within a workflow to not vary in isolation, so that the per-task `skip_worktree` escape hatch is gone and the policy is unambiguous.
3. As a developer running a one-off task through the UI, I want it to default to isolated, so that ad-hoc AI work doesn't pollute my main checkout by accident.
4. As a developer authoring a workflow that explicitly writes to main (e.g. a project-bootstrap workflow), I want to declare `isolated: false`, so that the workflow's outputs land directly without an extra merge step.
5. As a developer with two unrelated isolated workflows, I want them to run at the same time, so that I can move both forward concurrently.
6. As a developer running a non-isolated workflow, I want any second non-isolated workflow attempt to be refused with a clear error, so that I don't end up with two processes racing on my main checkout.
7. As a developer running one non-isolated and one isolated workflow, I want them to coexist, so that I can do background research in isolation while a foreground non-isolated workflow proceeds on main.
8. As a developer who tries to start an isolated workflow on a fresh directory with no `.git`, I want a clear refusal that explains the requirement, so that I know whether to `git init` or flip the workflow to non-isolated.
9. As a developer who tries to start an isolated workflow on a git repo with zero commits, I want the same clear refusal, so that I know to make an initial commit first.
10. As a developer browsing a workflow's running runs, I want to see which runs are isolated and which aren't, so that I can predict their effect on my checkout.
11. As a developer creating a task through the API, I want to be able to override the isolation default at create time, so that I can opt into the opposite behaviour for one-off tasks.
12. As a developer reading the workflow.yaml schema, I want `working_dir` and `external_repo` to not be framework concerns anymore, so that the framework's surface stays small and the task handles those itself.

## Implementation Decisions

Workflow YAML gains a top-level `isolated: bool` field. Default is `true`. The runtime, when starting a WorkflowRun, copies this flag onto the WorkflowRun record and uses it throughout the run's lifecycle.

Standalone tasks are materialised as a WorkflowRun-of-one. The API caller can supply an `isolated` argument; the default is `true`. The resulting WorkflowRun behaves identically to a single-task workflow run.

The concurrency rule is:

```
Test-CanStartRun(NewRun, ActiveRuns):
  if NewRun.isolated:
    return OK
  for run in ActiveRuns where run.status == 'running':
    if not run.isolated:
      return Conflict("Another non-isolated workflow is running: <id>")
  return OK
```

This is a pure function over a list of active runs. Owned by `Dotbot.Workflow`. The rule is consulted by the runtime (PRD-04) before transitioning a new WorkflowRun to `running`. A conflict returns HTTP 409 to the caller with a body describing the blocking run.

Before starting any isolated run, the runtime calls a git-ready check: `.git/` directory must exist and `git rev-list --count HEAD` must be > 0. On failure the start request is refused with the error:

```
Isolated workflows require a git repo with at least one commit on the base branch.
Either initialise git and commit first, or set 'isolated: false' on this workflow.
```

The per-task framework-recognised fields `skip_worktree`, `working_dir`, and `external_repo` are removed from TaskDefinition. Tasks that need to operate in a specific directory are responsible for changing directory themselves; the framework no longer interprets the fields.

A workflow.yaml linter rejects any TaskDefinition entry that contains `skip_worktree`. Existing workflow YAMLs are swept to add the top-level `isolated` and remove the per-task field.

Each task's `task_get_context` payload surfaces the parent WorkflowRun's `isolated` flag so the AI agent knows the operating mode.

## Testing Decisions

A good test for this PRD asserts on the rule, not the implementation. Given a list of active runs and a new run's isolation flag, does `Test-CanStartRun` return OK or Conflict?

Modules to be tested:
- **Dotbot.Workflow** (Test-CanStartRun) — the full truth table: first run of any kind = OK; isolated while isolated running = OK; isolated while non-isolated running = OK; non-isolated while isolated running = OK; non-isolated while non-isolated running = Conflict.
- **Dotbot.Workflow** (manifest parsing) — workflow.yaml with `isolated: true` parses correctly; workflow.yaml with per-task `skip_worktree` raises a lint error.
- **Dotbot.Workflow** (git-ready check) — empty directory refuses isolated; `.git` without commits refuses isolated; `.git` with one commit accepts.

Prior art: `tests/Test-WorkflowManifest.ps1` already validates workflow.yaml parsing — extend with the new `isolated` field and the lint rule. Pure-function rule tests sit alongside in a new test file.

## Out of Scope

- Worktree mechanics (how isolation is physically achieved): PRD-03.
- Where the concurrency rule fires (HTTP enforcement): PRD-04.
- Storage for the `isolated` flag on TaskInstance: it does not live on tasks; it lives on WorkflowRun (PRD-01 schema).
- Recovery / requeue behaviour when a non-isolated run is refused: the runtime returns 409 immediately. The UI can present a "try again later" affordance, but the runtime does not queue.

## Further Notes

- The default for new workflows is `isolated: true`. Authors that genuinely want main-checkout behaviour opt out explicitly.
- The runtime does not migrate existing workflow.yaml files — authors update them manually as part of the rewrite (covered by PRD-09's prompts sweep, which also touches workflow.yaml shape).
- Open question for implementor: should `task_get_context` include the entire WorkflowRun record or just the isolation flag plus run_id? Proposal: include the whole record; let the AI decide what's relevant.
