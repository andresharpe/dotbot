# Dotbot: Concepts and Assumptions

## Purpose
Dotbot wraps AI work in named units a human can review, approve, or discard. The framework structures *who is doing what, when, and where the records live*. Semantic decisions (commits, integration, merge strategy) stay with the user.

## Units of work
- **Task**: one piece of work producing a specific output.
- **Workflow**: an ordered set of tasks pursuing a goal.

A workflow's tasks share an execution context. A task created outside any workflow is a **workflow-of-one**.

## Templates and runs
A workflow is a *template* (`workflow.yaml`) declaring its TaskDefinitions. Each invocation creates a **WorkflowRun** that materialises TaskDefinitions into **TaskInstances**. The same workflow can run many times; each run is independent.

| Template | Runtime artifact |
|---|---|
| Workflow (`workflow.yaml`) | WorkflowRun |
| TaskDefinition (entry in `workflow.yaml.tasks`) | TaskInstance (JSON record) |

## Provenance
Every TaskInstance records its origin so "what tasks did this run produce?" is a definitive query:

```
provenance: { workflow, run_id, definition_name, expanded_by }
```

- `expanded_by` is `"workflow-expansion"` for tasks materialised at run start, or `"task:t_<id>"` for tasks created mid-run by another task. Standalone tasks have all four fields null.

## Identifiers and layout
- **Task IDs**: `t_` + 8-char nanoid. **WorkflowRun IDs**: `wr_` + 8-char nanoid.
- **Directory/filename short form**: the 4-char prefix of the canonical ID. Canonical IDs stay in JSON.
- **Schema versioning**: every record carries `schema_version`. Evolution is explicit; no silent shape changes.
- **Extensions**: core fields are closed; custom data goes under `extensions.<namespace>` (e.g. `extensions.workflow.start-from-repo`). Unknown core fields are rejected on write.

## Statuses

**Task lifecycle** (9 statuses):

```
Forward:   todo → analysing → analysed → in-progress → done
Pause:     analysing/analysed/in-progress → needs-input → analysing
Terminal:  failed | skipped | cancelled
Recovery:  done → todo (reopen)
           failed → todo (retry)
           skipped → todo (unskip)
           in-progress → analysed (kick-back)
```

`cancelled` is set by the cancellation cascade and is terminal-only (no recovery).

**WorkflowRun lifecycle**: `running → completed | failed | cancelled`. Completes when every required task is `done` (`skipped` doesn't block; `failed` of a required task fails the run; `cancelled` propagates from explicit user action).

Transitions are enforced as a closed table: anything not listed throws.

## Isolation
A workflow run is **isolated** (fresh git worktree on its own branch) or **non-isolated** (main checkout). Isolation exists for one reason: **to coexist with other concurrent work on the same repo without filesystem collision**.

Default: `isolated: true` for both workflows and standalone tasks. Overridable in `workflow.yaml` or at task-create time.

## Concurrency
- Any number of **isolated runs** can execute simultaneously, each in its own worktree.
- At most **one non-isolated run** at a time — they all want the main checkout.
- An isolated run and a non-isolated run can coexist.
- Attempting to start a second non-isolated run while one is active returns a conflict; clients decide whether to wait or surface the error.

## Worktree lifecycle
- **Per WorkflowRun**, not per task. Parallel tasks inside an isolated run share the worktree; `depends_on` orchestrates flow.
- **No junctions.** The worktree is a pure git checkout. Project state and live runtime state stay at canonical paths; the runtime resolves them per-run.
- **Path**: `../worktrees/<repo>/<YYYY-MM-DD>-<slug>-<4charID>/`. Branch: `workflow/<slug>-<4charID>` (or `task/<slug>-<4charID>` for standalone).
- **On completion** (success): worktree directory removed, branch kept.
- **On cancellation or failure**: uncommitted work captured as a final `wip:` commit on the branch; worktree directory removed; branch kept.
- **Integration**: the user merges, pushes, opens a PR, or discards. Dotbot produces branches; it does not auto-merge.
- **Precondition**: isolated runs refuse on a directory without `.git/` or with zero commits on the base branch.

## State location

| Where | What | Committed |
|---|---|---|
| `<project>/.bot/workspace/` | Task records, run records, product docs | Yes |
| `<project>/.bot/.control/` | Live status, heartbeats, activity log, runtime.json (address and token) | No (gitignored) |
| `<project>/.bot/src/` | Project-local framework code | No (gitignored) |
| `<project>/.bot/content/` | Default templates (prompts, agents, stacks) | No (gitignored) |
| `~/.dotbot/user-settings.json` | Global user-level settings (AI providers, theme, cost limit fallback) | No (per-user) |

Rule: *"If I clone this repo on another machine, should I see it?"* Yes → project state. No → machine or live state.

## Architecture

**One runtime process per active project workspace.** It is the **sole writer** of project state. Other components are clients.

```
Claude Code ──stdio──► MCP server ──┐
                                    │
                                    ├──HTTP─► Runtime ──files──► <project>/.bot/
Browser ──HTTP──► UI server ────────┘            ▲
   (same-origin)                                 │
                                      <project>/.bot/.control/runtime.json
                                            (URL + bearer token)
```

- Four cooperating processes, all on the same machine, all communicating over HTTP loopback. The MCP server speaks stdio to Claude Code (that's the MCP protocol) but is itself an HTTP client of the runtime.
- **Always HTTP, even local**: one codepath for state mutation; no shortcuts where a client bypasses the runtime.
- **Bearer-token auth** on every runtime request. The token lives in `<project>/.bot/.control/runtime.json` (mode 600 on POSIX, user-only ACL on Windows, gitignored). The browser never sees it — the UI server is its auth boundary.
- **Mutation invariants**: per-task and per-run in-memory mutex with canonical-ID-order acquisition (no deadlocks); every mutation carries an `actor` string (`ui:<user>`, `mcp:<session>`, `workflow:<run_id>`); runtime stamps `updated_by` + `updated_at`.
- **Transition hooks** run synchronously inside `Set-TaskStatus` with a per-hook `max_duration`. Hook failure with `abort_on_failure: true` reverts the transition.
- **Activity log** at `<project>/.bot/.control/activity.jsonl` is the runtime's event channel — append-only JSON lines. The UI's file watcher consumes it.

## Framework and projects
- The framework code is copied per-project under `<project>/.bot/src/` and `<project>/.bot/content/`.
- `dotbot init` creates `<project>/.bot/workspace/` and `.control/`, and copies the framework code into place. No global daemon registration is required.
- Upgrading dotbot is done by running `dotbot init` or a project upgrade script which re-copies the framework files into the project, taking care to preserve the git-versioned `workspace/` and customized `workflows/` folders.

## Plugins
Two plugin patterns, same shape:

- **Executors** (`runtime/Plugins/Executors/<name>/`): one folder per task `type`. Each has `metadata.yaml` + `script.ps1`. Initial set: `prompt`, `script`, `mcp`.
- **Transition hooks** (`runtime/Plugins/Hooks/Transitions/enter-<status>/`): one folder per status-entry side effect. Initial set: `enter-in-progress` (worktree ensure), `enter-done` (verification + commit info + session close), `enter-failed` (notification), `enter-skipped` / `enter-cancelled` (status aggregation only).

Both patterns are file-discovered at runtime startup. Adding a new executor or hook is dropping a folder.

## Workflow registry
Two tiers, resolved project-first:

1. `<project>/.bot/workflows/<name>/` — committed in the project; user-editable.
2. `<project>/.bot/content/workflows/<name>/` — shipped with the framework copy; updated on project init/upgrade.

Same name in both tiers → project tier wins. `dotbot workflow scaffold <name>` copies a built-in from `content/workflows/` into the project's own `workflows/` directory for customisation.

## Out of scope
- **Commits**: tasks commit on their own terms; the framework does not impose a commit policy.
- **Merge / PR strategy**: a finished isolated run is a branch; integration is the user's.
- **Where the AI works**: the task author chooses the working directory; framework no longer interprets `working_dir` or `external_repo`.

## Non-goals
- **No migration from v1**: this is a full rewrite. Legacy on-disk task layouts are not supported. Old projects stay on v3; new projects start clean on v4.
- **No backwards compatibility** on the MCP tool surface, the workflow.yaml schema, or the runtime API. Existing prompts/agents/workflows are rewritten in-place as part of the rewrite.
- **Decisions, plans, sessions** — present on v4 as first-class concepts but out of scope for this rewrite; they follow the same patterns later.
