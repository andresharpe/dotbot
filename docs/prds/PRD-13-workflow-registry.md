# PRD-13: Workflow registry

## Problem Statement

As a developer, I want to know exactly where workflows live and how to add a new one. Today v4 places workflows under `.bot/content/workflows/` inside each project. Post-PRD-11 the framework relocates to `~/.dotbot/framework/`. The PRDs reference "workflows" and `workflow_start` repeatedly but no PRD specifies whether workflows are shipped with the framework, defined per-project, or both.

## Solution

Workflows are **two-tier**: built-in workflows ship with the framework at `~/.dotbot/framework/workflows/`; project workflows live in `<project>/.bot/workflows/`. When the runtime resolves a workflow by name, it checks the project tier first, then the built-in tier. Project workflows can override built-ins by name. `workflow_list` reports both with a `source` field. Adding a new workflow means creating a folder in the appropriate tier.

## User Stories

1. As a developer using dotbot out of the box, I want `start-from-repo`, `start-from-prompt`, `start-from-pr`, `start-from-jira` to work without any setup, so that I can use the framework without authoring workflows.
2. As a developer authoring a project-specific workflow, I want to drop a folder into `<project>/.bot/workflows/` and have it discoverable from that project, so that workflow authoring is just file creation.
3. As a developer browsing my project's workflows, I want `workflow_list` to show both built-in and project workflows with a `source` field, so that I can tell which is which.
4. As a developer who needs to override a built-in (e.g. customise `start-from-repo` for my company's conventions), I want a project workflow with the same name to take precedence, so that I can tweak behaviour without forking the framework.
5. As a developer running `workflow_start <name>` from the UI or MCP, I want the resolution to be deterministic and explicit (project tier first, framework tier second), so that overrides behave predictably.
6. As a developer upgrading the framework, I want built-in workflows refreshed at `~/.dotbot/framework/workflows/` but my project overrides untouched, so that upgrades don't clobber local customisations.
7. As a developer authoring a workflow, I want the workflow's `workflow.yaml` and its `recipes/` folder (prompts, agents) to live together in one folder, so that the workflow is a self-contained unit.
8. As a developer copying a built-in workflow to start a customisation, I want a `dotbot workflow scaffold <name>` command (or equivalent) that copies a built-in into the project tier, so that I don't have to manually clone files.
9. As a developer reading the project's commit history, I want project workflows committed under `<project>/.bot/workflows/`, so that workflow code is versioned with the project.
10. As a developer reviewing a workflow before running it, I want to see its `workflow.yaml` and `recipes/` rendered in the UI, so that I know what it'll do.

## Implementation Decisions

**Workflow tiers**:
- **Framework tier**: `~/.dotbot/framework/workflows/<workflow-name>/`. Shipped with the framework, refreshed by `dotbot upgrade`. Read-only from the user's perspective (changes are overwritten on upgrade).
- **Project tier**: `<project>/.bot/workflows/<workflow-name>/`. Committed in the project. User-editable.

A workflow folder contains:
```
<workflow-name>/
  workflow.yaml          # the manifest (PRD-02 schema)
  recipes/
    prompts/
      *.md
    agents/              # optional
      *.md
```

**Resolution order** (in `Dotbot.Workflow.Find-Workflow`):
1. `<project>/.bot/workflows/<name>/workflow.yaml` — if present, use it.
2. `~/.dotbot/framework/workflows/<name>/workflow.yaml` — fallback.
3. None found → `WorkflowNotFound` error.

The resolved path is recorded on the WorkflowRun record so the run knows exactly which file it materialized from.

**Discovery** (`workflow_list` API):
- Scan `<project>/.bot/workflows/*/workflow.yaml` and `~/.dotbot/framework/workflows/*/workflow.yaml`.
- Parse each manifest (name, version, description, isolated).
- Return a flat list with `source: "project" | "framework"` per entry.
- If the same name appears in both tiers, report it once with `source: "project (overrides framework)"`.

**Scaffolding**:
- New CLI: `dotbot workflow scaffold <name>`.
- Copies `~/.dotbot/framework/workflows/<name>/` to `<project>/.bot/workflows/<name>/`.
- Prints a confirmation: "Copied built-in `<name>` to project. Edit `<project>/.bot/workflows/<name>/workflow.yaml` to customise."
- If the project already has a workflow by that name, refuses unless `--force`.

**Built-in workflows shipped**: at minimum the four current v4 workflows — `start-from-repo`, `start-from-prompt`, `start-from-pr`, `start-from-jira`. Each is rewritten per PRD-02 (top-level `isolated`) and PRD-09 (new MCP tool names in recipe prompts).

**Project workflows directory**: `dotbot init` creates `<project>/.bot/workflows/` as an empty directory (with a `.gitkeep`) so the location is visible.

**Permissions**:
- Framework tier is owned by the user (mode 700 via PRD-11). Refreshed by `dotbot upgrade`; user shouldn't edit by hand.
- Project tier follows project file conventions (committed, normal git permissions).

## Testing Decisions

A good test for this PRD operates against fixture directories representing both tiers, and asserts on resolution order and discovery results.

Modules to be tested:
- **Dotbot.Workflow** (Find-Workflow) — project-tier hit returns project path; project miss + framework hit returns framework path; both miss returns `WorkflowNotFound`; same name in both tiers returns project path.
- **Dotbot.Workflow** (Discover-Workflows) — returns all workflows from both tiers; `source` field populated correctly; duplicate names collapsed to one entry with override marker.
- **dotbot workflow scaffold** — copies framework workflow to project; refuses on existing name without `--force`; copies with `--force`.

Prior art: `tests/Test-WorkflowManifest.ps1` is the closest pattern — parses workflow.yaml and asserts on its shape. Extend with tier-resolution tests using tmp directories that simulate the two tiers.

## Out of Scope

- Workflow versioning / registry servers (pulling workflows from a URL or git remote) — defer; workflows are filesystem-local for this PRD.
- Sharing workflows across machines via a central catalog — defer.
- Workflow dependencies (one workflow inheriting tasks from another) — not in scope; each workflow is independent.
- A workflow editor in the UI — defer; users edit files.
- Validation of a workflow's recipe prompts (e.g. lint that prompts reference real MCP tool names) — covered partly by PRD-09's prompt hygiene tests; not a registry concern.

## Further Notes

- Symlinking from the project tier to a framework workflow is supported but not necessary — resolution covers the "use built-in" case without symlinks.
- A future addition could support a third tier at `~/.dotbot/user-workflows/` for personal workflows that span all projects on a machine. Out of scope for this PRD.
- Open question for implementor: should `workflow_list` filter to "runnable in this project's current state" (form-mode conditions evaluated)? Proposal: no — return all workflows; UI evaluates conditions to decide which buttons to render.
- The four built-in workflows shipped with the framework live in the source repo under `workflows/` (or similar). Install copies them to `~/.dotbot/framework/workflows/` during `install.ps1`. Upgrade overwrites them.
