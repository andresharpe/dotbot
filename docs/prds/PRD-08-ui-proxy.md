# PRD-08: UI server as HTTP proxy to runtime

## Problem Statement

As a user opening the dotbot dashboard in my browser, I expect my clicks to mutate the same state the MCP server and CLI mutate — without divergent code paths. Today the UI server owns task mutation logic directly (`TaskAPI.psm1` writes task files, runs its own validation, etc.); the MCP server has parallel logic for the same operations. Two writers of the same state, with subtle differences.

As an operator, I also expect the runtime's bearer token to stay server-side. The browser must never see it.

## Solution

Make the UI server a **thin proxy** for task and workflow operations: when the browser calls `/api/tasks/*` or `/api/workflows/*` on the UI server, the UI server translates the call into an authenticated request to the runtime. The runtime is the sole writer. The UI server is the auth boundary — the runtime token is loaded at UI startup and never leaks to the browser. State-synthesis modules (state for the dashboard, file watchers, notification pollers) stay in-process.

## User Stories

1. As a browser user, I want my task creates and status changes to land in the same data store the MCP server uses, so that the dashboard and the AI agent agree on state.
2. As a security-aware user, I want the runtime bearer token to never appear in my browser's memory or network responses, so that browser extensions and XSS can't pivot to runtime access.
3. As a browser user, I want every UI mutation to be attributed to me automatically (`actor: ui:<username>`), so that the audit log distinguishes my clicks from the AI's tool calls.
4. As a developer maintaining the UI, I want `TaskAPI.psm1` to contain no task mutation logic, so that there's only one place to fix a bug in task creation.
5. As a developer running the UI server, I want it to refuse to start if the runtime is unreachable, so that I don't get a half-working dashboard.
6. As a browser user, I want my existing /api/* endpoints to keep working with the same request/response shapes, so that the frontend code doesn't have to change.
7. As a browser user on the same host as the runtime, I want same-origin HTTP to the UI server (no CORS), so that the dashboard works without any auth dance in the browser.
8. As a developer working across multiple projects, I want the UI server to identify "the project it represents" at startup, so that I don't have to attach a project ID to every UI request.
9. As a developer maintaining auxiliary UI features (state synthesis, decision API, notification polling), I want them untouched, so that this rewrite has a contained blast radius.

## Implementation Decisions

`TaskAPI.psm1` is rewritten as a proxy:
- At UI server startup, resolve the runtime endpoint via `Dotbot.Runtime.Resolve-RuntimeEndpoint`.
- Resolve the project's ID from the runtime via `POST /projects` (idempotent if already registered).
- Cache the runtime URL, token, and project ID for the UI server's lifetime.

Each `/api/tasks/*` and `/api/workflows/*` handler translates the inbound request into an `Invoke-RuntimeRequest` call:

```powershell
function New-TaskFromUi {
    param([hashtable]$RequestBody)
    $body = $RequestBody + @{ project_id = $script:ProjectId; actor = Get-UiActor }
    return Invoke-RuntimeRequest -Method POST -Path "/tasks" -Body $body
}

function Set-TaskStatusFromUi {
    param([string]$TaskId, [string]$Status, [string]$Reason)
    $body = @{ project_id = $script:ProjectId; status = $Status; reason = $Reason; actor = Get-UiActor }
    return Invoke-RuntimeRequest -Method POST -Path "/tasks/$TaskId/status" -Body $body
}
```

`Invoke-RuntimeRequest` and `Resolve-RuntimeEndpoint` come from `Dotbot.Runtime` per PRD-04. `Get-UiActor` returns `"ui:$([Environment]::UserName)"`.

The frontend (`src/ui/static/*.js`) keeps calling `/api/...` on the UI server with the same shape it uses today. The proxy preserves the existing request and response contract; the browser sees no behavioural change.

Auth boundary:
- Browser ↔ UI server: same-origin HTTP. No bearer token, no CORS. Same as today.
- UI server ↔ runtime: bearer-token HTTP over loopback. The token is loaded once at startup and held in process memory only. It is never written into a response body, never echoed in a header, never logged.

If the runtime is unreachable at UI startup, the UI server refuses to start with: `"Runtime not running. Start it with 'dotbot go'."`

State-synthesis modules — AetherAPI, ControlAPI, ProductAPI, SettingsAPI, DecisionAPI, NotificationPoller, FileWatcher, InboxWatcher — are untouched. They continue to read project files directly and produce dashboard state for the frontend.

## Testing Decisions

A good test asserts on the **proxy contract**: given an inbound /api/ request, does the UI server make the right runtime call, and does it surface the right response/error to the browser?

Modules to be tested:
- **TaskAPI** (proxy behaviour) — fixture runtime captures inbound requests. UI calls /api/tasks → runtime sees POST /tasks with project_id and actor injected. UI calls /api/tasks/<id>/status → runtime sees POST /tasks/<id>/status.
- **TaskAPI** (auth boundary) — inspect outbound responses to the browser; assert that no value containing the runtime token appears.
- **TaskAPI** (startup refusal) — start UI with the runtime unreachable; assert the specific error message and non-zero exit.
- **TaskAPI** (response shape preservation) — inbound /api/ request returns a response shape identical to what v4 today returns (frontend contract preserved).

Prior art: the UI server startup test (`tests/Test-ServerStartup.ps1`) is the closest pattern for spinning up the UI in a test. Extend with a fixture runtime listener.

## Out of Scope

- The runtime itself: PRD-04.
- The MCP tools that call the same runtime endpoints: PRD-07.
- Frontend changes: the proxy preserves the /api/ contract; no JS changes required.
- Auxiliary UI modules (decisions, sessions, notifications, dashboard state synthesis): untouched.
- Dedup of the runtime-client helpers between UI and MCP: the helpers live in `Dotbot.Runtime` (PRD-04); UI imports them, MCP imports them.

## Further Notes

- The UI server is now privileged on behalf of the browser user. If it's compromised, the attacker has full runtime access. This is acceptable for a personal dev tool — the UI server already has full project-state write access today.
- The project ID is resolved once at startup. If the user moves the project directory while the UI is running, behaviour is undefined (the project's path no longer matches the registry). Restarting the UI re-registers correctly.
- Open question for implementor: WebSocket / SSE channels for activity stream — do they route through the runtime or stay file-watched on the UI server? Proposal: file-watched on the UI server for now; the runtime emits events into `.bot/.control/`, the UI server's existing watcher picks them up.
