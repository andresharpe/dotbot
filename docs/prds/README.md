# PRDs for the v4 rewrite

These PRDs implement the concepts and assumptions in [`../concepts.md`](../concepts.md) — locked across three grilling sessions.

Each PRD follows the project's PRD skill template: Problem Statement → Solution → User Stories → Implementation Decisions → Testing Decisions → Out of Scope → Further Notes.

## The PRDs

| PRD | Title | Module(s) |
|---|---|---|
| [PRD-01](PRD-01-data-model.md) | Canonical data model | Dotbot.Task |
| [PRD-02](PRD-02-isolation-and-concurrency.md) | Workflow isolation + concurrency rules | Dotbot.Workflow |
| [PRD-03](PRD-03-worktree-rewrite.md) | Worktree rewrite | Dotbot.Worktree |
| [PRD-04](PRD-04-runtime-http-server.md) | Runtime HTTP server + project registry | Dotbot.Runtime |
| [PRD-05](PRD-05-executors.md) | Plugin executors | Dotbot.Executor |
| [PRD-06](PRD-06-hooks.md) | Plugin transition hooks | Dotbot.Hook |
| [PRD-07](PRD-07-mcp-surface.md) | MCP tool surface | mcp/tools/* |
| [PRD-08](PRD-08-ui-proxy.md) | UI server as HTTP proxy | ui/modules/TaskAPI |
| [PRD-09](PRD-09-prompts-rewrite.md) | Prompts + agents rewrite | prompts/, agents/ |
| [PRD-10](PRD-10-test-reshape.md) | Test reshape | tests/ |
| [PRD-12](PRD-12-workflow-runtime-semantics.md) | Workflow runtime semantics | Dotbot.Workflow |
| [PRD-13](PRD-13-workflow-registry.md) | Workflow registry (project tier) | Dotbot.Workflow, <project>/.bot/workflows/ |

## Module ownership

Modified existing modules:
- **Dotbot.Task** — owns canonical TaskInstance schema, status enum, transition table, on-disk layout, ID generation.
- **Dotbot.Workflow** — owns workflow manifest parsing, WorkflowRun lifecycle, isolation rules (Test-CanStartRun), status aggregation.
- **Dotbot.Worktree** — owns per-run worktree creation/cleanup, branch operations, wip-commit-on-cancel, prune-branches.

New modules:
- **Dotbot.Runtime** — owns the project-scoped HTTP server, route table, bearer-token auth, in-memory mutex pool, and endpoint-discovery helpers (resolving via project-local `.control/runtime.json`).
- **Dotbot.Executor** — owns auto-discovery + dispatch for executor plugins (`prompt`, `script`, `mcp`).
- **Dotbot.Hook** — owns auto-discovery + invocation (with per-hook timeout) for transition hooks (`enter-<status>.ps1`).

## Dependency order

```
                                            PRD-04 (runtime) ──┐
                                                                ├─► PRD-05 (executors)
PRD-01 (data model) ───┐                                        ├─► PRD-06 (hooks)
                        ├─► PRD-03 (worktree)                    ├─► PRD-07 (MCP) ──► PRD-08 (UI proxy)
PRD-02 (isolation) ────┘                                        ├─► PRD-09 (prompts)
                                                                ├─► PRD-12 (workflow runtime)
PRD-13 (workflow registry) ────────────────────────────────────► PRD-12 (workflow runtime)
                       PRD-10 (tests) — lands incrementally with each PRD; end-of-series sweep
```

- **PRD-04** operates as a project-scoped server, initialized by a local project-setup step (`dotbot init`) copying the framework files to `.bot/`.
- **PRD-13** is a precondition for PRD-12: workflow expansion resolves workflow names against the registry tiers.
- **PRD-12** depends on PRD-04 (runtime mutex + HTTP), PRD-03 (worktree creation/cleanup it calls), PRD-06 (status-aggregation hook).

## Out of scope for this rewrite

Present on v4, not touched here: `decision-*`, `plan-*`, `session-*`, `dev-*` MCP tools; the .NET server at `src/server-dotnet/`; Studio UI at `src/studio-ui/`. Migration tooling is **deliberately out of scope** — this is a full rewrite; legacy v1 task storage is not supported.
