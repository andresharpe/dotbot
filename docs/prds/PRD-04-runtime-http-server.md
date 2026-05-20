# PRD-04: Runtime HTTP server + project registry

## Problem Statement

As a developer using dotbot, I want a single process per machine that owns all my project state — so that validation, locking, and state transitions live in one place rather than being duplicated across the UI server, the MCP server, and command-line scripts. Today v4 has no machine-wide runtime: the UI and MCP both call PowerShell modules in-process, each project has its own UI server, and there's no shared registry of which projects exist on the machine.

## Solution

Introduce a per-project runtime process discoverable via `<project>/.bot/`. It exposes a small HTTP API for task and workflow operations, authenticates with a bearer token, and is the sole writer of project state. The UI and MCP layers become clients of this runtime. Endpoint discovery falls back through env vars → settings → `<project>/.bot/.control/runtime.json` so callers always know where to look.

## User Stories

1. As a developer, I want one runtime process per project workspace, so that each project has a single, isolated source of truth for state mutations.
2. As a developer, I want the runtime's address and credentials in `<project>/.bot/.control/runtime.json` with restricted file permissions, so that other users on a shared machine cannot read my token.
3. As a developer, I want every state-mutating call to require a bearer token, so that off-loopback binding in the future is a config flip rather than a code change.
4. As a developer, I want the runtime to bind to 127.0.0.1 by default, so that I don't expose it on the network without thinking about it.
5. As a developer, I want `dotbot init` to lay out the project-local framework copies and workspace directory structure cleanly, so that the runtime is ready to be launched within the project workspace.
6. As a developer with multiple projects, I want each project's runtime to operate exclusively inside its own directory, so that there's no possibility of accidentally cross-contaminating or mutating the wrong project's state.
7. As a developer, I want the runtime to resolve its endpoint via env vars first, then settings, then `<project>/.bot/.control/runtime.json`, so that automated environments (CI, tests) can override the runtime location.
8. As a developer, I want `dotbot go` to start the runtime if it isn't already running, so that there's one obvious command to bring the system up.
9. As a developer, I want concurrent updates to the same task to not race, so that lost-writes can't happen even when the UI and an MCP call land at the same moment.
10. As a developer, I want concurrent updates to different tasks to proceed in parallel, so that locking doesn't serialise everything to one queue.
11. As a developer attempting two non-isolated workflows simultaneously, I want a clear conflict response, so that I know which run is blocking me.
12. As a developer running diagnostic checks, I want `dotbot runtime-status` to show PID, URL, and active runs, so that I can verify the runtime is healthy and see what it's tracking.
13. As a developer whose runtime crashed, I want `dotbot go` to detect a stale PID and rewrite the runtime file with a fresh token, so that the system recovers without manual cleanup.
14. As a developer running CI, I want the runtime to start on an ephemeral port, so that tests don't conflict on a fixed port.
15. As a developer using the MCP server in a Claude session, I want the MCP server to discover the runtime token automatically from the project's own `.bot/.control/runtime.json`, so that I don't have to configure each tool individually.
16. As a developer running cross-platform, I want the restricted file permissions on `runtime.json` to work on Windows (via NTFS ACL) as well as macOS/Linux (via mode 600), so that the security story is consistent.

## Implementation Decisions

The runtime connection file lives at `<project>/.bot/.control/runtime.json` — `{ url, token, pid, started_at }`. Restricted permissions: mode 600 on POSIX; user-only ACL on Windows.

The runtime is a single PowerShell process per active project workspace. It owns:
- An HTTP listener (System.Net.HttpListener) on 127.0.0.1, ephemeral port chosen at startup.
- A bearer-token check on every request (401 if missing/wrong).
- An in-memory `ConcurrentDictionary<string, SemaphoreSlim>` keyed by task ID for `Lock-TaskMutex`, and a parallel dictionary keyed by run ID for `Lock-RunMutex`. Multi-target operations acquire in canonical-ID-ascending order to prevent deadlocks.
- Endpoint discovery exported as `Resolve-RuntimeEndpoint`, used by both MCP tools (PRD-07) and the UI proxy (PRD-08): env vars `DOTBOT_RUNTIME_URL`/`DOTBOT_RUNTIME_TOKEN` > merged settings > `<project>/.bot/.control/runtime.json`.

The HTTP surface (used by PRD-07 MCP and PRD-08 UI):

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/tasks` | Create task |
| `GET` | `/tasks/<id>` | Get one task |
| `GET` | `/tasks` | List tasks (with filters) |
| `PATCH` | `/tasks/<id>` | Update non-status fields |
| `POST` | `/tasks/<id>/status` | Transition status |
| `GET` | `/tasks/next` | Next runnable task |
| `GET` | `/tasks/<id>/context` | Pre-built context |
| `POST` | `/workflows/runs` | Start a WorkflowRun |
| `GET` | `/workflows/runs/<id>` | Get one run |
| `GET` | `/workflows/runs` | List runs |

Every mutation request body carries an `actor` string (e.g. `ui:carlos`, `mcp:<session_id>`, `workflow:<run_id>`). The runtime stamps `updated_by` + `updated_at` on every mutation.

Starting a WorkflowRun calls `Test-CanStartRun` (PRD-02). A non-isolated conflict returns HTTP 409 with a body naming the blocking run.

**Event emission.** Every state-mutating operation also appends a single JSON line to `<project>/.bot/.control/activity.jsonl` (gitignored, per-project). The append is atomic (open in append mode, write one line, close). Line shape:

```jsonc
{
  "timestamp": "2026-05-18T10:00:00Z",
  "project_id": "p_AbCd1234",
  "type": "task_status_changed" | "task_created" | "task_updated" | "workflow_run_started" | "workflow_run_completed" | "workflow_run_failed" | "workflow_run_cancelled" | "hook_failed",
  "task_id": "t_xxxxxxxx",        // present when relevant
  "run_id": "wr_xxxxxxxx",         // present when relevant
  "from": "in-progress",           // present on transitions
  "to": "done",                    // present on transitions
  "actor": "ui:carlos",
  "reason": "..."                  // optional
}
```

The UI's existing FileWatcher (UI-side state synthesis, untouched by this rewrite) reads `activity.jsonl` as today. The runtime is the only writer.

This append-only event log replaces v4's scattered direct writes to `.control/activity.jsonl` from individual MCP tools. Tools that today add their own activity entries do so via the runtime, not directly.

Lifecycle:
- `dotbot go` checks `<project>/.bot/.control/runtime.json`. If file exists and its PID is alive, the runtime is already up; attach. Otherwise: generate fresh 64-hex-char token, scan for an open port (starting at a random offset in the IANA dynamic range 49152–65535), start the listener, write `runtime.json` under `.control/` with restricted permissions.
- On shutdown the runtime removes (or marks `pid: null` in) `runtime.json`.
- A stale runtime.json (PID not alive) is rewritten by the next `dotbot go` with a fresh token. Stale-token clients see 401 and re-discover.

The runtime-client helpers, mutex pool, and endpoint discovery all live inside the `Dotbot.Runtime` module — no separate `Dotbot.RuntimeClient` module. The MCP and UI clients import `Resolve-RuntimeEndpoint` and a thin `Invoke-RuntimeRequest` helper from `Dotbot.Runtime`.

`dotbot init` prepares the project workspace and copies the framework code. The runtime does not need to register projects since it runs strictly local to the active workspace.

## Testing Decisions

A good test for the runtime asserts on the **HTTP surface** — drive the listener with real HTTP requests, assert on response status, headers, and body. Auth and routing are externally observable; the mutex's effect is observable too (the final state after concurrent calls is deterministic and audit shows all updates).

Modules to be tested:
- **Dotbot.Runtime** (HTTP API) — every endpoint with valid auth = 2xx with expected body shape; missing/wrong auth = 401; illegal transition = 422; non-isolated concurrent run = 409.
- **Dotbot.Runtime** (mutex) — spawn 10 concurrent PATCH calls against the same task; final state contains all updates (no lost writes); audit log shows them in some order.
- **Dotbot.Runtime** (endpoint discovery) — set env var → returns env; unset env, set settings → returns settings; unset both → returns `<project>/.bot/.control/runtime.json` content; nothing available → throws "runtime not running".
- **Dotbot.Runtime** (lifecycle) — stale-PID runtime.json is rewritten with a fresh token on `dotbot go` after scanning and finding an open port; shutdown cleans up.

Prior art: there's no HTTP-against-listener test pattern in v4 today. Establish one in this PRD's test file by starting the runtime in a background job within the test, then using `Invoke-WebRequest` / `Invoke-RestMethod` against the ephemeral port. The pattern in `tests/Test-ServerStartup.ps1` (UI server) is the closest precedent for spinning up a listener and asserting on it.

## Out of Scope

- The MCP tools that call this HTTP surface: PRD-07.
- The UI proxy that calls this HTTP surface: PRD-08.
- Plugin executors invoked by the runtime: PRD-05.
- Transition hooks invoked during status changes: PRD-06.
- Remote (off-loopback) deployment: bind defaults to 127.0.0.1; off-loopback works behind a flag but operational concerns (TLS, network policy) are not designed here.
- Background-daemon mode: the runtime is foreground when launched by `dotbot go`. A `dotbot serve` background-mode command can come later.

## Further Notes

- The mutex pool is in-memory and single-process. Multi-runtime scenarios would need a different story (file locks, external coordinator); not in scope.
- The bearer token regenerates on every fresh start. Clients with a cached stale token see 401 and re-discover via `Resolve-RuntimeEndpoint`. This is acceptable for the local-dev case.
- **Open question for implementor: exact REST endpoint shapes.** The table above (`POST /tasks/<id>/status`, `PATCH /tasks/<id>`, etc.) is my proposed shape. Confirm or adjust before implementing — the runtime client wrappers in MCP and UI consume whatever shape the runtime exposes.
- **Open question for implementor: activity-log event-type vocabulary.** The proposed types (`task_created`, `task_status_changed`, `workflow_run_started`, etc.) need confirming. The UI's current event consumer (FileWatcher) reads `activity.jsonl` as today — make sure the new shape doesn't break the consumer or update the consumer in step.
- Open question for implementor: should `POST /projects` accept a desired `id` for idempotent recovery (e.g. from a backup)? Proposal: yes; if `id` is supplied and the path matches an existing entry, return it; if `id` mismatches, 409. If `id` is absent, generate.
