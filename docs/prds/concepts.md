# Dotbot: Concepts and Assumptions

## Purpose
Dotbot wraps AI work in named units a human can review, approve, or discard.

## Units of work
- **Task**: one piece of work producing a specific output.
- **Workflow**: an ordered set of tasks pursuing a goal.

A workflow's tasks share an execution context. A task created outside a workflow is a **workflow-of-one**.

## Templates and runs
A workflow is a template (`workflow.yaml`). Each invocation creates a **WorkflowRun**; the same workflow runs many times, each independently. Same at task scale: TaskDefinition is the template entry; TaskInstance is one execution. Every TaskInstance records its origin (workflow, run, definition entry). Standalone tasks have none.

## Isolation
A workflow run is **isolated** (fresh git worktree on its own branch) or **non-isolated** (main checkout). Isolation exists for one reason: to coexist with other concurrent work without filesystem collision.

Default: isolated. Overridable per workflow.

## Concurrency
- Any number of isolated runs run simultaneously.
- One non-isolated run at a time.
- Isolated and non-isolated can coexist.

## What an isolated run produces
On completion or cancellation: worktree directory removed, branch kept. On cancellation, uncommitted work is captured as a final commit. Dotbot produces branches; the user merges, pushes, opens a PR, or discards.

## State location
| Where | What | Committed |
|---|---|---|
| `<project>/.bot/workspace/` | Tasks, runs, docs | Yes |
| `<project>/.bot/.control/` | Live status, heartbeats, activity log | No |
| `~/.dotbot/` | Runtime address, token, project registry | No |

Rule: "If I clone this repo on another machine, should I see it?" Yes → project. No → machine or live.

## Runtime
One runtime process per user per machine. The only writer to project state. UI and MCP are HTTP clients. Each request names its project. Runtime can move to another machine later without client changes.

## Statuses
Task: `todo → analysing → analysed → in-progress → done`. Terminal alternatives: `failed`, `skipped`. Recovery transitions: `done → todo`, `failed → todo`.

WorkflowRun: `running → completed | failed | cancelled`. Completes when every required task is `done`.

## Layout reflects time
Workflow runs: date-prefixed directories under `workspace/tasks/workflow-runs/`. Standalone tasks: date-prefixed single files under `workspace/tasks/standalone/`. Listing = chronological view.

## Out of scope
- **Commits.** Tasks commit on their own terms.
- **Merge/PR strategy.** A finished isolated run is a branch; integration is the user's.
- **Where the AI works.** Task-author concern.

Dotbot decides *who, when, where records live*. Semantics stay with the user.
