# PRD-10: Test reshape

## Problem Statement

As a developer maintaining the codebase, I want the test suite to reflect the new modules (data model, isolation, worktree, runtime, executors, hooks, MCP surface, UI proxy) so that CI can catch regressions in any of them. Today's tests are tightly bound to the old surface (`task-mark-*` tools, per-status folders, junction setup, patch-replay merge) — they will break en masse when PRDs 01–09 land.

## Solution

Add a new test file per major module. Update overlapping tests to assert on the new behaviour. Remove tests for the removed surface. Layers 1–3 of the test pyramid stay green across Windows / macOS / Linux against the new design. Each PRD lands its own tests; this PRD is the end-of-series sweep that ensures nothing was missed.

## User Stories

1. As a developer running `pwsh tests/Run-Tests.ps1` after the rewrite, I want layers 1–3 to pass on macOS, so that local dev iteration is unblocked.
2. As a developer running CI on Windows and Linux, I want the same suite to pass, so that the rewrite stays portable.
3. As a developer reading the test suite, I want one test file per major module, so that I know where to add a test when I touch a module.
4. As a developer writing a new test, I want a clear "good test" rule: assert on external behaviour, not implementation details, so that tests don't drift when I refactor internals.
5. As a developer fixing a regression, I want each test file to use the same harness (Run-Tests.ps1 layers), so that I don't have to learn multiple test frameworks.
6. As a developer reading test output, I want clear pass/fail per module, so that I can diagnose breakage quickly.
7. As a developer reviewing a PRD's PR, I want that PRD's tests to be in the same PR, so that the suite never goes red between PRDs.
8. As a developer removing the old surface, I want every test referencing it removed too, so that there's no dead test code asserting on phantom behaviour.

## Implementation Decisions

A good test in this suite asserts on **externally observable behaviour**: a function's return value, a thrown exception, a file written, an HTTP response, an audit log entry. Tests should not poke at internal helpers or assert on intermediate state that has no observable consequence.

New test files (one per module under test):
- **Test-DataModel** — TaskInstance / WorkflowRun / TaskDefinition schema validation, unknown-field rejection, `extensions` namespace roundtrip.
- **Test-Transitions** — every valid forward + recovery edge, every illegal edge throws with both states named in the error.
- **Test-WorkflowRun** — WorkflowRun lifecycle (`running → completed | failed | cancelled`), status aggregation when tasks complete, optional vs required task semantics.
- **Test-Worktree** — per-run worktree creation, naming, no junctions, completion-keeps-branch, cancellation-wip-commit, no-git refusal, two-concurrent-isolated-runs.
- **Test-Runtime-HTTP** — endpoint matrix with valid auth (2xx with right shape), missing/wrong auth (401), unknown project (404), illegal transition (422), non-isolated concurrent run (409), mutex (concurrent updates land deterministically).
- **Test-EndpointDiscovery** — env → settings → file fallback cascade.
- **Test-Executors** — discovery, dispatch by `task.type`, required_fields validation, unknown-type error, max-duration timeout.
- **Test-Hooks** — discovery, invocation on target status, max_duration timeout, abort_on_failure behaviour.
- **Test-MCPSurface** — every new MCP tool issues the correct runtime call (method/path/body/headers), error mapping, actor injection.
- **Test-UIProxy** — UI server proxies /api/* to runtime, token never appears in browser-bound responses, refuses startup without runtime.
- **Test-PromptHygiene** — grep-style assertions that the prompt corpus contains no removed tool names or removed task-level concepts.

Updated test files:
- **Test-Components** — replace `task-mark-*` coverage with new-surface coverage; update settings chain integration tests.
- **Test-WorkflowManifest** — add workflow-level `isolated` parsing; assert lint rejects per-task `skip_worktree`.
- **Test-MockClaude** — flow exercises new tool names (`task_create`, `task_set_status`, `workflow_start`).
- **Test-Structure** — update module-existence assertions: new (`Dotbot.Runtime`, `Dotbot.Executor`, `Dotbot.Hook`), removed (`TaskMutation`, `TaskIndexCache`, `TaskFile`, `TaskStore` if collapsed).
- **Test-Workflow*Integration*** — end-to-end: start a run, expand tasks, transition statuses via the new HTTP surface, assert run completes with branch preserved and worktree cleaned up.

Removed test files (or substantial removals within larger files):
- Any test that asserts on `task-mark-*` MCP tools directly.
- Any test using per-task `skip_worktree`.
- Any test mocking `Apply-TaskBranchPatch` / patch-replay merge.
- Any test asserting on junction directories under a worktree.

Test layer mapping:
- **Layer 1 (Structure)**: Test-Structure updates, Test-DataModel, Test-Transitions, Test-EndpointDiscovery (pure functions, no runtime).
- **Layer 2 (Components)**: Test-Worktree, Test-Executors, Test-Hooks, Test-MCPSurface, Test-PromptHygiene, Test-WorkflowManifest, Test-Components.
- **Layer 3 (Mock Claude)**: Test-Runtime-HTTP, Test-WorkflowRun, Test-UIProxy, Test-MockClaude, Test-Workflow*Integration*.
- **Layer 4 (real Claude)**: unchanged for this PRD; updates land in a follow-up after the new surface stabilises.

Each PRD lands its own tests as part of its PR. This PRD's role is the **closing sweep**: confirm coverage, delete the test debt left by removed surface, ensure the layered runner is green end-to-end.

## Testing Decisions

This PRD *is* about testing. The test suite itself is the deliverable.

Prior art for test patterns:
- Pester-style assertions: existing `tests/Test-WorkflowManifest.ps1` is the closest pattern; reuse for schema and rule tests.
- Spinning up an HTTP listener in-test: `tests/Test-ServerStartup.ps1` is the closest precedent; extend with auth headers for runtime tests.
- Tmp git repos: use `New-Item -ItemType Directory` + `git init` + an initial empty commit; tear down in an `AfterAll` block.
- Fixture plugin directories: tmp folders with throwaway `metadata.yaml` + `script.ps1` that record their invocation, used to test the discovery + dispatch contract.

## Out of Scope

- Layer 4 (real Claude API) updates — deferred until the new surface is stable in production.
- Performance / load tests for the runtime — functional correctness is enough for this PRD.
- End-to-end integration tests beyond Layer 3 mock-Claude — the Layer 3 suite is the goalpost.
- Test framework migration (Pester → something else) — keep the existing runner.

## Further Notes

- Test suite runtime target: Layer 2 < 60 seconds, Layers 1–3 combined < 5 minutes. If a new test pushes us over, profile and tighten.
- Tests use ephemeral ports for the runtime; the listener reports its actual port, and clients use it. No fixed port collisions in CI.
- Cross-platform path construction in tests must use `Join-Path` everywhere (no `/` literals). Windows CI catches the difference fast.
- Open question for implementor: should we add an end-to-end smoke test that spins up the runtime, registers a project, starts a workflow, and asserts on every observable layer? Proposal: yes — call it `Test-FullFlow.ps1`, run it as part of Layer 3. Useful as the single best signal of "the rewrite hangs together".
