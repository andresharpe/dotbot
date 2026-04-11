# Issue 123: Manual Test Cases for Refactored Functions

Use this document to manually exercise each call path that was affected by the duplicate-function consolidation.
For each refactored function, the table lists where and how to trigger its use so you can observe correct behaviour.

---

## Step 1 (DONE): `Send-McpRequest`

**Canonical location**: `tests/Test-Helpers.psm1`
**Removed from**: 16 × `workflows/default/systems/mcp/tools/*/test.ps1`

### Verification

The automated test suite is the use case. Run:

```powershell
pwsh tests/Run-Tests.ps1 -Layer 2
```

All 16 MCP tool tests now import the shared implementation. A full Layer 2 pass confirms every tool can start the MCP process, send a request, and parse the response using the canonical `($Process, $Request)` parameter order.

---

## Step 2 (DONE): `Write-Status`

**Canonical location**: `workflows/default/systems/runtime/modules/DotBotTheme.psm1`
**Removed from**: `scripts/Platform-Functions.psm1`, `stacks/dotnet/hooks/dev/Common.ps1`

### Scripts — install / CLI path

| Script / entry point | How to trigger | What to look for | Result |
|---|---|---|---|
| `install.ps1` | `pwsh install.ps1` | Cyan `›` status lines during install — PS version check, already-installed detection, update detected |V |
| `scripts/init-project.ps1` | `dotbot init` in a new or existing project | `.bot` initialisation progress, workflow install lines, Claude Code integration line | V |
| `scripts/init-project.ps1` | `dotbot init --stack dotnet` | Stack-specific install lines (`Installing workflow:`, `Running init script`) | V |
| `bin/dotbot.ps1` | `dotbot studio` while studio is already running | `Opening browser...` line | bug blocked |
| `scripts/workflow-add.ps1` | `dotbot workflow add <name>` | `Installing workflow: <name>` | bug blocked |
| `scripts/workflow-remove.ps1` | `dotbot workflow remove <name>` | `Removing workflow: <name>` | bug blocked add |
| `scripts/workflow-run.ps1` | `dotbot workflow run <name>` | Task count message + `Launching workflow process...` | bug blocked add |
| `scripts/registry-add.ps1` | `dotbot registry add --name myorg --source <local-dir-with-registry.yaml>` | `Creating symlink: ...` followed by registry name and content summary | x |
| `scripts/registry-list.ps1` | `dotbot registry list` (after add above) | Registry count line + per-entry name, type, and available stacks/workflows | x |
| `scripts/registry-update.ps1` | `dotbot registry update` (after add above) | `Updating N registry(ies)` — local symlink re-validates; git registries fetch/pull | x |

> **Registry prerequisite**: a local folder containing a valid `registry.yaml` (fields: `name`, `version`, `stacks`, `workflows`). Without one the `add` command rejects the source and the other two rows cannot be reached.

### Runtime / web UI path

| Module | How to trigger | What to look for | Result |
|---|---|---|---|
| `ControlAPI.psm1` | Web UI → start analysis on a task | `Launched analysis process with model: ...` (Success type, green) | |
| `ControlAPI.psm1` | Web UI → start execution on a task | `Launched execution process with model: ...` (Success type, green) | |
| `ControlAPI.psm1` | Web UI → Reset button | `Reset complete - cleared all stale state` (Success type, green) | |
| `ProcessAPI.psm1` | Web UI → stop a process | `Stop signal sent to process <id>` (Info type, cyan) | |
| `ProcessAPI.psm1` | Web UI → kill a process | `Killed process <id> (PID: ...)` (Warn type, amber) | |
| `ProcessAPI.psm1` | Web UI → stop all processes of a type | `Stop signal sent to N <type> process(es)` | |
| `ProcessRegistry.psm1` | Resume a task that had answered its question | `Found resumed task (question answered): <name>` in server log | |
| `AetherAPI.psm1` | Aether bonded / unlinked (if configured) | `Aether bonded to ... with N node(s)` / `Aether unlinked` | |

### dotnet-stack dev hooks

| Script | How to trigger | What to look for | Result |
|---|---|---|---|
| `stacks/dotnet/hooks/dev/Stop-Dev.ps1` | Inside a dotnet-stack project: `dotbot stop` | Dev lifecycle status messages (`Info` type — *not* `Neutral`, which was the pre-fix bug) | |

---

## Step 3 (DONE): `Send-Whisper` → `Send-WhisperToSession` / `Send-WhisperToInstance`

**After rename:**
- `Send-WhisperToSession` — `workflows/default/hooks/scripts/steering.ps1`
- `Send-WhisperToInstance` — `workflows/default/systems/ui/modules/ControlAPI.psm1`

### `Send-WhisperToSession` (steering / MCP path)

| Scenario | How to trigger | Expected | Result |
|---|---|---|---|
| Normal steering heartbeat | MCP `steering-heartbeat` tool sends a message while a task is in-progress | Whisper file appears in `.bot/.control/whispers/<session-id>/` | |
| Operator whisper mid-run | MCP tool `steering-whisper` (or direct call with `-SessionId`) | Message file written; agent picks it up on next heartbeat | |
| Abort signal | Operator calls the abort path in `steering.ps1` | Whisper with `ABORT:` prefix written; agent commits in-progress work and exits | |

### `Send-WhisperToInstance` (web UI path)

| Scenario | How to trigger | Expected | Result |
|---|---|---|---|
| Whisper via web UI | POST `/api/whisper` body `{ "instance_type": "execution", "message": "pause" }` | `Whisper sent to N execution process(es)` logged; whisper file appears | |
| Interrupt running analysis | Web UI "Send Whisper" button while analysis is running | Message delivered to analysis session whisper dir | |
| No matching processes | POST `/api/whisper` for a type with no live processes | `Whisper sent to 0 process(es)` — no error | |

---

## Step 4 (DONE): `Get-TasksBaseDir`, `Get-TodoTaskRecord`, `Get-RoadmapOverviewDependencyMap`

**Canonical location after consolidation:**
- `Get-TasksBaseDir` → `TaskStore.psm1`
- `Get-TodoTaskRecord` → `TaskStore.psm1`
- `Get-RoadmapOverviewDependencyMap` → `TaskMutation.psm1`

**Delegates added to:** `TaskAPI.psm1` (UI), `StateBuilder.psm1` (roadmap)

### `Get-TasksBaseDir`

| Code path | How to trigger | Expected | Result |
|---|---|---|---|
| MCP task creation | Create a task via MCP tool `task-create` | Task file appears in `<project>/.bot/workspace/tasks/todo/` | |
| MCP task move | `task-move-to` tool moves a task to `in-progress` | File moves from `todo/` to `in-progress/` subdirectory | |
| UI task listing | Web UI → Tasks tab | Task list populated from correct directory | |
| UI task edit | Edit task description in web UI | Edit written to the correct task file | |
| Test path injection | Pass `$TasksBaseDir` override in a unit test | Custom tmp path used; real `.bot/` directory untouched | |

### `Get-TodoTaskRecord`

| Code path | How to trigger | Expected | Result |
|---|---|---|---|
| MCP: `task-update` | Update any task field via MCP | Current record returned before delta is applied | |
| MCP: `task-move-to` | Move task state | Record resolved; task id, name, content all present | |
| MCP: `task-set-context` | Set context block on a task | Record fetched; only context field updated | |
| UI: task edit | Edit task in web UI | Record includes `id`, `name`, `content` fields | |
| UI: task delete | Delete task from web UI | Record confirmed before removal | |
| UI: restore version | Restore historical version via web UI | Record fetched to confirm task exists before restore | |
| UI: ignore | Toggle ignore state | Record retrieved; `ignored` flag toggled | |

### `Get-RoadmapOverviewDependencyMap`

| Code path | How to trigger | Expected | Result |
|---|---|---|---|
| MCP: `get-bot-state` | Call `get-bot-state` MCP tool | Response includes `roadmap.dependencies` map populated from roadmap docs | |
| UI: Roadmap tab | Open web UI → Roadmap tab | Phase dependency graph renders correctly | |
| No roadmap docs | Remove or rename roadmap markdown files temporarily | Both MCP and UI return empty dependency map with no error | |
| Mixed present / absent phases | Comment out one roadmap phase file | Only present phases appear in the dependency map | |

---

## Step 5 (DONE): Update task-domain tests after helper consolidation

**Added assertions (automated, in `Test-TaskActions.ps1`)**:
- `TaskMutation exports Get-RoadmapOverviewDependencyMap`
- `TaskStore exports Get-TasksBaseDir`
- `TaskStore exports Get-TodoDirectories`
- `TaskStore exports Ensure-TodoDirectories`
- `TaskStore exports Get-TodoTaskRecord`
- `TaskStore defines canonical Get-TodoTaskRecord` (file-content check)
- `TaskMutation does not define Get-TodoTaskRecord` (file-content check confirming delegation)
- `StateBuilder delegates roadmap dependency map to TaskMutation` (file-content check)

All assertions pass in Layer 2 (87 total in Task Action Source Tests suite).

---

## Step 6 (TODO): `Get-TaskSlug`

**Canonical location after consolidation**: `TaskStore.psm1`
**Removed from**: `TaskMutation.psm1`, `WorktreeManager.psm1`

Algorithm (WorktreeManager's, adopted as canonical):
1. Lowercase
2. Collapse any run of non-alphanumeric characters to a single `-`
3. Trim leading/trailing `-`
4. Cap at 50 chars; strip any trailing `-` after truncation

### Algorithm boundary cases

| Input | Expected slug | Property tested | Result |
|---|---|---|---|
| `Implement User Auth` | `implement-user-auth` | Lowercase + spaces → dashes | |
| `Add   multiple   spaces` | `add-multiple-spaces` | Runs of spaces collapsed | |
| `  Leading and trailing  ` | `leading-and-trailing` | Edge-dash trimming | |
| `Feature/Sub-Task (2)` | `feature-sub-task-2` | Non-alphanumeric collapse | |
| 60-char `A` string | `aaaa...a` (50 chars, no trailing dash) | 50-char cap + cleanup | |
| `Update: API (v2)` | `update-api-v2` | Mixed special chars | |
| `---already-slugged---` | `already-slugged` | Edge-dash trim on already-clean input | |

### Integration use cases

| Code path | How to trigger | Expected | Result |
|---|---|---|---|
| Task reference alias | Create task via `task-create`; call `get-bot-state` | `references` map contains `@<slug>` alias (e.g., `implement-user-auth`) | |
| Worktree branch name | Start execution on a task | `task/{short-id}-{slug}` git branch created; slug ≤ 50 chars | |
| Alias and branch consistent | Create task then start execution | `@` reference alias slug matches the branch-name tail exactly | |
| Long task name | Create task with 80-char name | Both alias and branch tail truncated identically at 50 chars, no trailing dash | |
