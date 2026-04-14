# Issue 123: Duplicate Function Consolidation Plan

## Challenge Assessment

- Issue: Consolidate duplicate PowerShell function definitions across modules where signature drift or ambiguous ownership creates bugs.
- Soundness: 100%
- Why this is sound:
  - The reported duplicates exist in the current tree.
  - At least one duplicate set already caused a real bug around `Write-Status` import behavior (PowerShell runs the most recently imported same-name command; importing the wrong module last silently replaces the intended implementation).
  - Several duplicates represent shared task-domain logic that has already drifted.
  - All design questions are resolved in the step definitions and consolidation categories.

## Context Sources

- GitHub issue 123: duplicate function audit and suggested approach.
- `CLAUDE.md`
- `scripts/Platform-Functions.psm1`
- `stacks/dotnet/hooks/dev/Common.ps1`
- `workflows/default/systems/runtime/modules/DotBotTheme.psm1`
- `workflows/default/systems/runtime/modules/WorktreeManager.psm1`
- `workflows/default/systems/mcp/modules/TaskMutation.psm1`
- `workflows/default/systems/mcp/modules/TaskStore.psm1`
- `workflows/default/systems/ui/modules/TaskAPI.psm1`
- `workflows/default/systems/ui/modules/StateBuilder.psm1`
- `workflows/default/systems/ui/modules/ControlAPI.psm1`
- `workflows/default/hooks/scripts/steering.ps1`
- `tests/Test-Helpers.psm1`
- `tests/Test-TaskActions.ps1`

## Classes Dependency Hierarchy

### Level 0: Shared Helper Ownership Decisions

- `TaskStore.psm1` — receives `Get-TasksBaseDir` (canonical) and `Get-TodoTaskRecord` (canonical, rich shape from `TaskMutation.psm1`)
  - Responsibility: Own task-directory resolution and todo-record lookup for both MCP and UI layers.
  - Reason: Issue explicitly names `TaskStore.psm1` as the consolidation target for path resolution. Grouping `Get-TodoTaskRecord` here keeps storage layout knowledge co-located.

- `TaskMutation.psm1` — retains `Get-RoadmapOverviewDependencyMap` as canonical host
  - Responsibility: Roadmap dependency parsing stays in the module that owns task data. `StateBuilder.psm1` delegates to this version.
  - Issue direction: "likely TaskMutation since it owns task data."
  - **Dependency direction note**: `systems/ui/` modules (`TaskAPI.psm1`, `StateBuilder.psm1`) depend on modules under `systems/mcp/`. This is a deliberate cross-system dependency that should be made explicit in any module manifest or import comments so future contributors do not reverse it.
  - **No new module needed** — `TaskStore.psm1` and `TaskMutation.psm1` absorb all consolidations.

- `dotbot-mcp-helpers.ps1` (already exists)
  - Responsibility: JSON-RPC response/error writers and date parsing helpers for MCP tool tests. Does **not** own `Send-McpRequest` — that is test infrastructure and belongs in `Test-Helpers.psm1`.
  - Placement: `workflows/default/systems/mcp/dotbot-mcp-helpers.ps1` — already dot-sourced by every tool test.ps1.

### Level 1: Shared Task-Domain Consumers

- `TaskMutation.psm1`
  - Responsibility: Continue to own task mutation workflows, but stop owning duplicated general-purpose task helper implementations.
  - Depends on: `TaskStore.psm1`.

- `TaskAPI.psm1`
  - Responsibility: UI-facing task operations should consume the same task lookup and path-resolution helpers as MCP.
  - Depends on: `TaskStore.psm1`.

- `StateBuilder.psm1`
  - Responsibility: Continue building UI state, but read roadmap dependency fallback data through the shared task-domain helper.
  - Depends on: `TaskMutation.psm1`.

### Level 2: Naming Clarification Consumers

- `Platform-Functions.psm1`
  - Responsibility: Keep install and script output helpers. `Write-Status` is removed from this module (Step 2) — it had no `-Type` support and caused load-order bugs.

- `Common.ps1`
  - Responsibility: Remove local `Write-Status` definition; import from `DotBotTheme.psm1` instead.

- `DotBotTheme.psm1`
  - Responsibility: The canonical runtime/UI themed status writer — sole source of `Write-Status` after Step 2.

- `steering.ps1`
  - Responsibility: Hosts `Send-WhisperToSession` (renamed from `Send-Whisper` in Step 3) — sends a whisper to a specific session/process target.

- `ControlAPI.psm1`
  - Responsibility: Hosts `Send-WhisperToInstance` (renamed from `Send-Whisper` in Step 3) — sends a whisper to one or more running instances selected by type.

- `WorktreeManager.psm1`
  - Responsibility: Delegates `Get-TaskSlug` to `TaskStore.psm1` (Step 6). Slug generation is unified; WorktreeManager removes its local definition and imports the canonical algorithm.
  - Note: The 50-char truncation in WorktreeManager is a **Windows MAX_PATH defensive measure** (worktree paths become subdirectories on disk), not a Git protocol requirement. Git itself imposes no branch name length limit; `git check-ref-format` enforces character rules only.

## Consolidation Categories

### Category A: Safe Quick Wins

- `Send-McpRequest`
  - Consolidate into `tests/Test-Helpers.psm1` — it is test infrastructure and that is where it belongs.
  - Remove the embedded copies from all 15 MCP tool `test.ps1` files; each file gains one `Import-Module` for `Test-Helpers.psm1`.
  - **Parameter order must be unified**: `Test-Helpers.psm1` declares `($Process, $Request)`; tool test copies declare `($Request, $Process)`. All current call sites use named parameters so both work today, but the canonical version must pick one order and all callers audited for any positional use.
  - Update `README-NEWTOOL.md`: the `test.ps1` template currently shows an inline `Send-McpRequest` definition — replace it with an `Import-Module Test-Helpers` line.

- `Get-TodoTaskRecord`
  - **Issue recommendation accepted**: Consolidate into `TaskStore.psm1` or `TaskMutation.psm1`; `TaskAPI.psm1` calls the shared version.
  - **Concretization**: Host in `TaskStore.psm1` — groups path resolution (`Get-TasksBaseDir`) and record lookup together; both are storage layout concerns. The issue lists both modules as acceptable; `TaskStore.psm1` is the tiebreaker choice here.
  - Use the richer `TaskMutation.psm1` record shape (`todo_dir`, `edited_dir`, `deleted_dir`, `tasks_base_dir`) as the canonical result.

- `Get-RoadmapOverviewDependencyMap`
  - **Issue recommendation accepted**: "Consolidate into one location (likely TaskMutation since it owns task data). StateBuilder calls the shared version."
  - No new module needed — canonicalize the `TaskMutation.psm1` version; remove the `StateBuilder.psm1` duplicate.
  - Preserve existing roadmap-overview parsing behavior.

### Category B: Shared Logic With Signature Alignment

- `Get-TasksBaseDir`
  - **Issue recommendation accepted**: "Consolidate into `TaskStore.psm1` as the single source. TaskMutation and TaskAPI should call TaskStore's version."
  - **Concretization**: The optional override param from `TaskMutation.psm1` (`param([string]$TasksBaseDir)`) is preserved as a local wrapper in `TaskMutation.psm1` if needed for test injection. Issue says "if truly needed" — keep it conditional on test-coverage requirements.

### Category C: Accepted Recommendations

- `Write-Status`
  - **Issue recommendation accepted**: Remove `Write-Status` from `Platform-Functions.psm1` — it is the odd one out (no `-Type` support). `DotBotTheme.psm1` is the single source of truth for runtime and UI contexts.
  - `Common.ps1` in the dotnet stack should import from `DotBotTheme.psm1` or have its local definition removed if `DotBotTheme` is always available in that context.
  - No rename needed for `DotBotTheme.psm1` — existing `-Type` call sites already target the correct implementation.

- `Send-Whisper`
  - **Issue recommendation accepted**: Rename to clarify targeting model.
  - **Concretization**: Use `Send-WhisperToSession` (`steering.ps1`) and `Send-WhisperToInstance` (`ControlAPI.psm1`) — the specific names the issue suggests.
  - Optionally share a low-level whisper-file append helper in a follow-up; the public rename is the priority.

### Category D: Accepted Recommendation

- `Get-TaskSlug`
  - **Issue recommendation accepted**: extract into a shared module and use the WorktreeManager algorithm as the canonical implementation.
  - The WorktreeManager version is a strict superset of the TaskMutation version: it lowercases first, collapses any non-alphanumeric run to a single dash, trims leading/trailing dashes, and caps at 50 chars. The TaskMutation version does none of the last three.
  - There is no scenario where the weaker TaskMutation algorithm is preferable for worktree naming; adopting the stronger one in both places is safe.
  - Target module: `TaskStore.psm1` — already imported by `TaskMutation.psm1`, avoids a new file, and sits in a location both consumers can reach. `SharedUtils.psm1` is not needed.

## Implementation Steps

### Step 1: Consolidate `Send-McpRequest` into `Test-Helpers.psm1`

- Files to modify:
  - `tests/Test-Helpers.psm1` — ensure `Send-McpRequest` is defined here with the canonical parameter order; align with the version in the tool tests if needed
  - `workflows/default/systems/mcp/tools/*/test.ps1` — remove the 15 embedded `Send-McpRequest` definitions; add `Import-Module` for `Test-Helpers.psm1` in each file
  - `workflows/default/systems/mcp/README-NEWTOOL.md` — replace the inline `Send-McpRequest` block in the `test.ps1` template with an `Import-Module Test-Helpers.psm1` line
- Purpose:
  - Make `Test-Helpers.psm1` the single authoritative source for `Send-McpRequest` — it is test infrastructure and belongs there.
  - Resolve the latent parameter order reversal (`($Process, $Request)` vs `($Request, $Process)`) as part of the same change.
  - Keep `dotbot-mcp-helpers.ps1` free of test-only concerns; it remains the home for production MCP script helpers (JSON-RPC writers, date parsing).
- Serena: use `safe_delete_symbol` on each tool test's `Send-McpRequest` before removing it to confirm no other callers exist. Use `replace_content` (regex) to bulk-remove the function definition blocks across all 15 files.
- Expected risk: Low
- Checkpoint: `Send-McpRequest` is defined once in `Test-Helpers.psm1`. No local definitions remain in tool `test.ps1` files. `README-NEWTOOL.md` template no longer shows an inline definition.

### Step 2: Remove `Write-Status` from `Platform-Functions.psm1` and redirect `Common.ps1`

- Files to modify:
  - `scripts/Platform-Functions.psm1`
  - `stacks/dotnet/hooks/dev/Common.ps1`
  - `workflows/default/systems/runtime/modules/DotBotTheme.psm1`
  - call sites in install scripts, stack hooks, and runtime/UI scripts as needed
- Pre-work — call-site classification (do this before any edits):
  - Use `find_referencing_symbols` to enumerate every `Write-Status` call site.
  - Classify each into one of two groups:
    - **Group A — calls with `-Type`**: currently broken if `Platform-Functions.psm1` loads last (the bug #122 surfaced). After removal these work correctly as long as `DotBotTheme.psm1` is imported by their script.
    - **Group B — calls without `-Type`**: currently resolved by `Platform-Functions.psm1`. After removal they must import `DotBotTheme.psm1` instead. Visual output is identical: `DotBotTheme.psm1` defaults `-Type` to `'Info'`, which renders the same `›` cyan-muted line as the `Platform-Functions.psm1` version.
  - For every Group B call site, confirm `DotBotTheme.psm1` is (or will be) imported by that script. Add the import where missing as part of this step.
- Purpose:
  - Remove `Write-Status` from `Platform-Functions.psm1` — it is the odd one out with no `-Type` support (issue direction: this is a removal, not a rename).
  - Remove or redirect `Common.ps1`'s copy to import from `DotBotTheme.psm1`.
  - Make `DotBotTheme.psm1` the sole `Write-Status` source for runtime and UI contexts.
  - Ensure every call site — with or without `-Type` — is served by `DotBotTheme.psm1` via an explicit import, not by load-order luck.
- Serena: use `find_referencing_symbols` for the pre-work classification. Use `safe_delete_symbol` on `Platform-Functions.psm1`'s definition to confirm the Group B call-site list is complete before deletion. Use `replace_symbol_body` to redirect `Common.ps1`'s copy if it cannot simply be removed.
- Expected risk: Medium
- Checkpoint: `DotBotTheme.psm1`'s `Write-Status` is the sole definition. Every call site (with and without `-Type`) imports `DotBotTheme.psm1` explicitly. No `Write-Status` definition remains in `Platform-Functions.psm1`.

### Step 3: Rename `Send-Whisper` to `Send-WhisperToSession` and `Send-WhisperToInstance`

- Files to modify:
  - `workflows/default/hooks/scripts/steering.ps1`
  - `workflows/default/systems/ui/modules/ControlAPI.psm1`
  - `workflows/default/systems/ui/server.ps1`
  - related tests if added or updated
- Purpose:
  - Rename `Send-Whisper` in `steering.ps1` → `Send-WhisperToSession` and in `ControlAPI.psm1` → `Send-WhisperToInstance` — the specific names the issue suggests.
  - Avoid same-name functions with different semantics.
- Serena: use `rename_symbol` on each `Send-Whisper` definition independently (scoped to its file) to apply the chosen name. Codebase-wide reference updates are automatic.
- Expected risk: Low
- Checkpoint: `Send-WhisperToSession` exists in `steering.ps1` and `Send-WhisperToInstance` exists in `ControlAPI.psm1`. No `Send-Whisper` definition remains in either file.

### Step 4: Consolidate task path and record helpers into `TaskStore.psm1` and `TaskMutation.psm1`

- Files to create or modify:
  - `workflows/default/systems/mcp/modules/TaskStore.psm1` — add `Get-TasksBaseDir` (canonical) and `Get-TodoTaskRecord` (canonical, rich shape); remove its existing weaker `Get-TasksBaseDir`
  - `workflows/default/systems/mcp/modules/TaskMutation.psm1` — retain `Get-RoadmapOverviewDependencyMap` as canonical; delegate `Get-TasksBaseDir` and `Get-TodoTaskRecord` to `TaskStore.psm1`
  - `workflows/default/systems/ui/modules/TaskAPI.psm1` — delegate `Get-TasksBaseDir` and `Get-TodoTaskRecord` to `TaskStore.psm1`
  - `workflows/default/systems/ui/modules/StateBuilder.psm1` — delegate `Get-RoadmapOverviewDependencyMap` to `TaskMutation.psm1`
  - No new module — issue-named existing modules absorb all consolidations
- Purpose:
  - Establish one owner per function per issue assignment: `TaskStore.psm1` for path/record helpers, `TaskMutation.psm1` for roadmap dependency parsing.
  - Prevent UI and MCP task behavior from drifting further.
- Serena: use `find_referencing_symbols` on each function before moving it to enumerate every consumer precisely. Use `replace_symbol_body` to replace each duplicate body with a delegation call once the shared module exists.
- Expected risk: Medium
- Checkpoint: One canonical owner exists for `Get-TasksBaseDir`, `Get-RoadmapOverviewDependencyMap`, and `Get-TodoTaskRecord`. All consumers import from the shared module.

### Step 5: Update task-domain tests after helper consolidation

- Files to modify:
  - `tests/Test-TaskActions.ps1`
  - `tests/Test-Components.ps1`
  - any MCP or UI tests that assume the old helper ownership
- Purpose:
  - Verify shared helpers work through both MCP and UI code paths.
  - Preserve task lookup, ignore-state, and roadmap fallback behavior.
- Expected risk: Medium
- Checkpoint: MCP and UI task flows both pass against the shared helper implementation. Ignore-state and roadmap fallback behavior is unchanged.

### Step 6: Consolidate `Get-TaskSlug` into `TaskStore.psm1`

- Files to modify:
  - `workflows/default/systems/mcp/modules/TaskStore.psm1` — add the canonical `Get-TaskSlug` (WorktreeManager algorithm)
  - `workflows/default/systems/mcp/modules/TaskMutation.psm1` — remove local definition; import from `TaskStore.psm1`
  - `workflows/default/systems/runtime/modules/WorktreeManager.psm1` — remove local definition; import from `TaskStore.psm1`
  - tests covering task creation and worktree naming
- Algorithm to use: WorktreeManager's — lowercase first, collapse any non-alphanumeric run to a single dash, trim edge dashes, cap at 50 chars with trailing-dash cleanup.
- Purpose:
  - Ensure task-reference aliases and worktree branch names are generated by the same algorithm so they cannot diverge for the same task name.
  - Eliminate the weaker TaskMutation variant.
- Serena: use `find_referencing_symbols` on each consumer's `Get-TaskSlug` to confirm call sites before removing. Use `replace_symbol_body` to replace each local definition with a delegation shim or remove it after the import is in place.
- Expected risk: Medium because branch-name behavior and task-reference behavior may already be relied on indirectly.
- Note: The 50-char cap is a Windows MAX_PATH guard for worktree subdirectory paths, not a Git naming constraint. It must be preserved in the shared algorithm.
- Checkpoint: One `Get-TaskSlug` exists in `TaskStore.psm1`. Both `TaskMutation.psm1` and `WorktreeManager.psm1` import and call it. No local definitions remain.

## Testing Requirements

### Functional Scenarios

- MCP tool tests can still start the MCP process, send requests, and parse responses after `Send-McpRequest` consolidation.
- UI and MCP task operations resolve the same base task directory in normal repo execution.
- Test paths that inject a temporary tasks base directory still work.
- Roadmap-overview dependency fallback remains identical for task mutation and UI state building.
- Todo task lookup returns the same task records expected by edit, delete, restore, and ignore flows.

### Regression Scenarios

- Importing output helper modules no longer changes behavior based on load order.
- Runtime/UI scripts that use `Write-Status -Type ...` continue to work with the intended implementation.
- Stack-local dev hooks still emit readable status output after any rename or consolidation.
- Session-targeted steering and instance-targeted UI whispers still write the expected whisper files.
- Long task names do not create mismatched task references or invalid worktree branch names after any slug decision.

### Test Execution

- Run install/update cycle from repo root:
  - `pwsh install.ps1`
- Run layers 1-3:
  - `pwsh tests/Run-Tests.ps1`
- If iteration is needed, run the smallest targeted test file first, then rerun the full suite at the end.

## Serena Tool Guidance

The Serena MCP server is available for this project and changes the risk profile and execution approach for several steps.

### Tool-to-step mapping

- `find_referencing_symbols` — use before every step to generate a precise LSP-backed call-site map. Replaces grep-based discovery and eliminates the risk of missing a call site.
- `safe_delete_symbol` — use in Step 1 before removing each embedded `Send-McpRequest` copy. Returns a reference list if any callers exist, preventing silent breakage.
- `replace_content` (regex mode) — use in Step 1 to bulk-remove the embedded function definitions from the 15 tool `test.ps1` files in a single targeted pass.
- `replace_symbol_body` — use in Step 4 to replace duplicate function bodies with delegation calls once the shared module is in place.
- `rename_symbol` — use in Step 3. Performs a codebase-wide rename including all call sites. This is the primary reason that step has a Low risk rating despite touching multiple files.
- `get_symbols_overview` — use when exploring a module before editing to avoid reading the full file.

