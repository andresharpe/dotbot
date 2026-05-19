# PRD-07: MCP tool surface

## Problem Statement

As a Claude agent operating in dotbot, I want a small, focused set of tools whose names and inputs are easy to learn. Today the MCP surface has many overlapping tools (one per status transition: `task_mark_done`, `task_mark_analysing`, …, plus `task_answer_question`, `task_approve_split`, `task_create_bulk`, etc.) and each tool has its own implementation logic. As a developer maintaining the surface, I want each tool to be a thin wrapper over a single runtime — not a re-implementation that drifts from the UI's behaviour.

## Solution

Replace the existing surface with **ten focused tools**: seven for tasks (create, get, list, update, set-status, get-next, get-context) and three for workflows (start, get, list). Each tool is a thin HTTP wrapper that calls the runtime (PRD-04). Validation, locking, and side effects live in the runtime, not the tool. The status-change tool (`task_set_status`) describes every status and its side effects in its own metadata so the agent can pick the right transition.

## User Stories

1. As a Claude agent, I want a small tool catalog so I can hold it in working memory without losing track.
2. As a Claude agent transitioning a task, I want one tool with a status enum, so that I don't have to remember which `task_mark_*` matches which status.
3. As a Claude agent reading `task_set_status`'s description, I want each status' side effects listed inline, so that I can pick the right transition without guessing.
4. As a Claude agent creating a task, I want a single `task_create` tool that accepts all the task fields, so that I don't need a separate bulk variant.
5. As a Claude agent looking up a specific task, I want `task_get` (which doesn't currently exist on v4), so that I can read state by ID.
6. As a Claude agent editing a task's metadata (not status), I want `task_update` separate from `task_set_status`, so that field edits don't get tangled with state transitions.
7. As a Claude agent starting a workflow, I want `workflow_start` to materialise tasks and return the run record, so that one tool call kicks off the run.
8. As a Claude agent, I want every mutation to be attributed to me automatically (`actor: mcp:<session>`), so that audit shows who did what without me supplying it.
9. As a Claude agent, I want the tool to fail with a clear MCP error when the runtime says 401/404/409/422, so that I can see the message and adjust.
10. As a Claude agent, I want every tool to operate within the project workspace of the connected runtime, so that I never accidentally mutate the wrong project's state.
11. As a developer maintaining the MCP surface, I want each tool's `script.ps1` to be a few lines (resolve endpoint → HTTP call → return), so that the tool layer has no logic.
12. As a developer adding a new runtime endpoint, I want adding the corresponding MCP tool to be a folder copy with two file edits, so that the surface stays cheap to extend.
13. As a developer, I want the old `task_mark_*` / `task_answer_question` / `task_approve_split` / `task_create_bulk` / `task_get_stats` tools to be gone after this lands, so that the surface is unambiguous about which tool to use.
14. As a developer of decisions/plans/sessions tools, I want my tools left untouched by this PRD, so that I can migrate them on a separate cadence.

## Implementation Decisions

**MCP server lifecycle.** The MCP server is a stdio process at `<project>/.bot/src/mcp/dotbot-mcp.ps1` (copied locally per project). Claude Code spawns one instance per project session, with the project directory as cwd, per the entry recorded in `<project>/.bot/.mcp.json`. On startup the server:

1. Reads the runtime endpoint via `Resolve-RuntimeEndpoint` (PRD-04 cascade: env → settings → `<project>/.bot/.control/runtime.json`). If the runtime isn't running, the MCP server exits with a clear stderr message; Claude Code surfaces it.
2. Resolves the active project context directly from its local environment (since the runtime is strictly project-scoped).
3. Caches `{ runtime_url, runtime_token, session_id }` in process memory.
4. Auto-discovers tools from `<project>/.bot/src/mcp/tools/`.

For each tool invocation:
1. The MCP server dispatches to the tool's `script.ps1`.
2. The tool calls `Invoke-RuntimeRequest` (exported from `Dotbot.Runtime`) with the cached endpoint + token, injecting `actor: "mcp:<session_id>"` into the body.
3. The runtime response (or error) is returned to Claude through the MCP protocol.

The MCP server is stateless across calls beyond the cached endpoint info. There is no in-process task store, no shared file lock, no PowerShell-module dependency that mutates state — the runtime owns all of that.

## Tool surface

The ten tools, each as a folder under the MCP tools directory:

| Tool | Method | Runtime path |
|---|---|---|
| `task_create` | POST | `/tasks` |
| `task_get` | GET | `/tasks/<id>` |
| `task_list` | GET | `/tasks` |
| `task_update` | PATCH | `/tasks/<id>` |
| `task_set_status` | POST | `/tasks/<id>/status` |
| `task_get_next` | GET | `/tasks/next` |
| `task_get_context` | GET | `/tasks/<id>/context` |
| `workflow_start` | POST | `/workflows/runs` |
| `workflow_get` | GET | `/workflows/runs/<id>` |
| `workflow_list` | GET | `/workflows/runs` |

Each tool's script is a few lines:

```powershell
function Invoke-TaskSetStatus {
    param([hashtable]$Arguments)
    $body = @{
        status     = $Arguments.status
        reason     = $Arguments.reason
        actor      = Get-McpActor   # from Dotbot.Runtime helpers
    }
    Invoke-RuntimeRequest -Method POST -Path "/tasks/$($Arguments.task_id)/status" -Body $body
}
```

`Invoke-RuntimeRequest` and `Get-McpActor` are exported from the `Dotbot.Runtime` module (the runtime-client helpers live there per PRD-04's consolidation). The MCP tool layer imports these helpers and contains no other logic.

Every mutation tool injects `actor: "mcp:<session-id>"` from the environment. Read tools don't carry an actor.

Each tool's `metadata.yaml` describes the input schema in JSON Schema. `task_set_status`'s schema enumerates the eight statuses and the description lists side effects so the agent can pick correctly:

> "Transition a task to a new status. Each status triggers side effects: `analysing` begins analysis; `analysed` marks analysis complete; `in-progress` ensures the worktree exists (if isolated) and starts execution; `done` runs verification hooks (gitleaks, framework integrity, commit-info), then closes the Claude session; `failed` archives diagnostic state and emits a notification; `skipped` is terminal with no side effects; `cancelled` is terminal (typically set by the cancellation cascade from a parent WorkflowRun; no recovery); `needs-input` pauses execution; `todo` is a recovery transition from `done`/`failed`/`skipped` (reopen/retry/unskip — note: `cancelled` is terminal and cannot recover)."

Tools removed from the surface entirely: `task-mark-todo`, `task-mark-analysing`, `task-mark-analysed`, `task-mark-in-progress`, `task-mark-done`, `task-mark-skipped`, `task-mark-needs-input`, `task-answer-question`, `task-approve-split`, `task-create-bulk`, `task-get-stats`. The MCP modules that backed them (`TaskMutation`, `TaskStore`, `TaskIndexCache`, `TaskFile`) are removed too — that logic lives in `Dotbot.Task` invoked via the runtime.

Tools left untouched (out of scope for this rewrite): `decision-*`, `plan-*`, `session-*`, `dev-*`, `steering-heartbeat`.

Tool error mapping: a runtime 401 surfaces as MCP "authentication error"; a 404 surfaces as "not found"; a 409 surfaces as "conflict" with the body message; a 422 surfaces as "invalid transition" or "validation error" depending on the body shape.

## Testing Decisions

A good test asserts on the **HTTP boundary** the tool produces — given some arguments, did the tool send the right request method, path, body, and headers, and did it surface the right MCP error when the runtime returned a non-2xx? Tests should not assert on what happens inside the runtime — that's PRD-04's territory.

Modules to be tested:
- MCP tools dispatcher (test each tool sends the right HTTP request) — fixture runtime that captures the request and returns canned responses. Assert: right method/path/body, bearer token attached, actor populated on mutations.
- Error mapping — fake runtime returns 401/404/409/422 with sample bodies; assert the tool's MCP error message contains the body's user-facing text.
- The new tools' metadata — schema lints clean (valid JSON Schema), required fields enumerated, `task_set_status` description lists all eight statuses.

Prior art: there's no HTTP-mocking test pattern in v4's MCP tests today. Establish one in this PRD's test file using a tmp HttpListener as a fake runtime. The pattern in `tests/Test-ToolLocal.ps1` (loading and inspecting tool metadata) is reusable for static checks.

## Out of Scope

- The runtime endpoints the tools call: PRD-04.
- Validation, locking, side effects: PRD-01, PRD-04, PRD-05, PRD-06.
- The UI proxy that calls the same runtime endpoints: PRD-08.
- Updating framework prompts and agents to reference the new tool names: PRD-09.
- The decisions/plans/sessions/dev tool families: untouched.

## Further Notes

- Each tool's `script.ps1` should be under fifteen lines. If a tool needs more code, the logic belongs in the runtime, not the tool.
- The bearer token, runtime URL, and MCP session ID are all environment-derived in the tool layer. The agent never supplies them.
- Open question for implementor: should `task_create` accept `isolated` for standalone tasks here (mirroring the runtime), or only on the runtime? Proposal: mirror — accept and pass through. The runtime is still the authority.
