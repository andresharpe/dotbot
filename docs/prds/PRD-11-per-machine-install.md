# PRD-11: Per-machine install + framework relocation

## Problem Statement

As a developer using dotbot across several projects, I want to install the framework once on my machine and have every project share it — not pay for a full copy of the framework code inside every project's `.bot/` directory. Today dotbot's install puts `dotbot` on my PATH, but `dotbot init` then copies the entire framework (`core/`, hooks, recipes, prompts, agents) into each project. Upgrades require re-running init in every project, framework drift is easy, and the runtime can't run as one machine-wide process because each project has its own copy of the runtime code.

## Solution

Relocate the framework code to a machine-wide location at install time. `dotbot init` becomes a tiny operation that creates the project's workspace skeleton, registers the project with the runtime, and wires up IDE integration — no framework code copied. The runtime starts from the machine-wide framework. Upgrading the framework is one install command; every project on the machine picks up the new version on the next runtime restart.

## User Stories

1. As a developer running `install.ps1` for the first time, I want the framework code dropped at a known machine-wide location, so that I don't pay a copy cost per project.
2. As a developer running `install.ps1`, I want the `dotbot` CLI added to my PATH, so that I can run `dotbot init` / `dotbot go` from any directory.
3. As a developer running `install.ps1`, I want the per-user `~/.dotbot/` skeleton created (with restricted permissions), so that the runtime has a place to write its state file.
4. As a developer running `dotbot init` in a new project, I want only project-local state created (workspace/, .control/), so that the project's `.bot/` stays small and gitignored cleanly.
5. As a developer running `dotbot init`, I want the project registered with the runtime via `POST /projects`, so that the runtime knows where my project lives.
6. As a developer running `dotbot init`, I want MCP server registration written to my IDE configs (`.claude/`, `.codex/`, `.gemini/`) pointing at the machine-wide MCP server, so that the AI knows how to reach dotbot from this project.
7. As a developer upgrading dotbot, I want one command (`dotbot upgrade` or re-running `install.ps1`) to refresh the machine-wide framework, so that every project picks up the new version.
8. As a developer upgrading dotbot, I want the runtime restarted automatically (or with a single command), so that the new framework takes effect immediately.
9. As a developer with several projects on disk, I want them all to use the same framework version, so that I can't accidentally have stale framework code in one project.
10. As a developer cloning an existing project on a new machine, I want `dotbot init` (or `dotbot register`) to attach the project to my machine's runtime without copying framework code, so that the onboard is fast.
11. As a developer reviewing a project's committed `.bot/`, I want to see only workspace state (tasks, runs, product docs), so that the diff isn't drowned by framework code I can't influence.
12. As a developer browsing my home directory, I want machine state and framework code in distinct subdirectories of `~/.dotbot/`, so that I can clean up state without disturbing code (and vice versa).
13. As a developer running on Windows, macOS, and Linux, I want the install paths to follow each platform's conventions but otherwise behave identically, so that I can switch machines without retraining.
14. As a developer running a privacy scan over a project's `.mcp.json`, I want the path to the machine-wide MCP server to be allow-listed (rather than tripping as an "absolute path"), so that the privacy scan stays useful.
15. As a developer cleaning up after uninstalling dotbot, I want `~/.dotbot/` to be the only place to delete, so that removal is one step.

## Implementation Decisions

The machine-wide install root is `~/.dotbot/` on every platform (POSIX path; on Windows this resolves to `%USERPROFILE%\.dotbot\`). Within it, framework code and machine state are kept in separate subdirectories:

```
~/.dotbot/
  framework/         # code (overwritten on upgrade)
  runtime.json       # state — runtime URL, token, PID (mode 600)
  projects.json      # state — registered projects
  install.json       # version, install date, install method
```

`framework/` mirrors the source layout (`src/`, `scripts/`, etc.) so the runtime can run directly from it. Permissions on `~/.dotbot/` are user-only (mode 700 on POSIX; user-only ACL on Windows). The `dotbot` CLI wrapper resolves the framework location from `install.json` so it doesn't hard-code a path.

`install.ps1` is reshaped:
- Detects existing install via `install.json`; on re-run, becomes an upgrade.
- Copies the framework into `~/.dotbot/framework/` (atomic via tmp directory + rename).
- Ensures `dotbot` is on PATH (adds shell-rc lines as needed for bash/zsh/PowerShell profiles; idempotent).
- Creates `~/.dotbot/` skeleton with correct permissions.
- Writes `install.json`: `{ version, install_method, install_date, framework_dir }`.
- Does NOT start the runtime; that's `dotbot go`.

`dotbot init` is reshaped to project-only work:
- Creates `<project>/.bot/workspace/` with the layout from PRD-01 (`tasks/workflow-runs/`, `tasks/standalone/`, `product/`, `decisions/` skeletons).
- Creates `<project>/.bot/.control/` (gitignored).
- Updates `<project>/.gitignore` with the project-local gitignore entries (`.bot/.control/`, etc.) and the privacy-scan-allowed paths.
- Writes `<project>/.mcp.json` pointing at `~/.dotbot/framework/src/mcp/dotbot-mcp.ps1` (absolute path). Updates the privacy-scan allowlist to include this exact path so the scan stays clean.
- Writes `<project>/.claude/`, `.codex/`, `.gemini/` MCP server entries pointing at the same machine-wide MCP server.
- Calls `POST /projects` on the running runtime to register. If the runtime isn't running, prints the standard "start it with 'dotbot go'" message; the registration is idempotent on retry.
- Copies no framework code anywhere. The project's `.bot/` contains only `workspace/` and `.control/`.

A new CLI command `dotbot upgrade`:
- Re-runs the install (downloads or re-copies the framework to `~/.dotbot/framework/`).
- Restarts the runtime if it's running.
- Reports the version delta.

A new CLI command `dotbot register <project_path>`:
- Idempotent register of an existing project (no workspace creation). Useful after cloning a project that was set up on a different machine.

The MCP server (`~/.dotbot/framework/src/mcp/dotbot-mcp.ps1`) reads the calling cwd or an explicit `--project` argument to determine which project context to use, then resolves the project_id from the runtime's `projects.json`.

The runtime (`~/.dotbot/framework/src/runtime/server.ps1`) is started by `dotbot go`. It serves all registered projects. If a project's path on disk no longer exists when an API call references it, the runtime returns 410 Gone with a hint to either `dotbot register` the project from a new path or remove it from the registry.

Per-project `.bot/` after `dotbot init`:

```
<project>/.bot/
  workspace/
    tasks/
      workflow-runs/
      standalone/
    product/
    decisions/
  .control/
    workflow-runs/      # gitignored, per PRD-04
    processes/          # gitignored
    activity.jsonl      # gitignored
```

No `core/`, `hooks/`, `recipes/`, `agents/`, `prompts/`, `settings/`, `systems/` directories under the project's `.bot/`. All of those live in `~/.dotbot/framework/`.

`Dotbot.Settings` chain is updated:
- Default settings: `~/.dotbot/framework/settings/settings.default.json`.
- User settings: `~/.dotbot/user-settings.json`.
- Project settings: `<project>/.bot/.control/settings.json` (gitignored) or `<project>/.bot/settings.json` (committed) — pick one, document.

## Testing Decisions

A good test for this PRD operates against a tmp `HOME` directory and a tmp project directory and asserts on what's where after the install + init.

Modules to be tested:
- **install.ps1** — fresh install: creates `~/.dotbot/framework/`, `runtime.json` absent, `install.json` present, `dotbot` on PATH. Re-run install: upgrades framework (newer timestamp), `install.json` updated.
- **dotbot init** — fresh project: creates project's `.bot/workspace/` and `.bot/.control/`; no `core/` or framework subdirs under `.bot/`; `.mcp.json` points at `~/.dotbot/framework/src/mcp/dotbot-mcp.ps1`; idempotent on re-run.
- **dotbot init** (no runtime) — prints the "start it with 'dotbot go'" message and exits non-zero; running `dotbot go` then `dotbot init` succeeds.
- **dotbot upgrade** — re-copies framework; if runtime running, runtime restarts.
- **dotbot register** — registers a project without creating workspace skeleton.
- **Privacy scan** — `.mcp.json` containing the canonical `~/.dotbot/framework/...` path does not trigger a privacy violation.
- **Cross-platform paths** — Windows install resolves `%USERPROFILE%\.dotbot\`; macOS/Linux resolves `$HOME/.dotbot/`; both produce equivalent layouts.

Prior art: `tests/Test-Structure.ps1` asserts on file/directory existence at install time — extend it for the new layout. The existing privacy-scan tests under `tests/Test-PrivacyScan.ps1` show how to verify allowlist behaviour for paths.

## `dotbot` CLI surface

After this PRD lands, the full `dotbot` command surface is:

| Command | Owner PRD | Purpose |
|---|---|---|
| `dotbot init` | PRD-11 | Create project workspace, register with runtime, write IDE configs. |
| `dotbot register [<path>]` | PRD-11 | Register an existing project (no workspace creation). |
| `dotbot go` | PRD-04 | Start the runtime (and the UI). |
| `dotbot upgrade` | PRD-11 | Re-copy framework to `~/.dotbot/framework/`, restart runtime. |
| `dotbot runtime-status` | PRD-04 | Show runtime PID, URL, registered projects, active runs. |
| `dotbot prune-branches` | PRD-03 | Clean up accumulated `workflow/*` and `task/*` branches. |
| `dotbot workflow scaffold <name>` | PRD-13 | Copy a built-in workflow into the project tier for customisation. |

CLI commands live under `src/cli/<command>.ps1`. The `dotbot` PATH wrapper dispatches by first argument. Each command parses its own arguments and exits with a clear status. No global flags beyond `--help`.

## Pre-commit hook

`dotbot init` installs `<project>/.git/hooks/pre-commit` as a small stub that invokes `~/.dotbot/framework/scripts/pre-commit.ps1 <project-path>`. The framework-side script runs the gitleaks + privacy scan chain and exits non-zero on findings. Because the actual logic lives in the framework, upgrading dotbot upgrades the pre-commit behaviour automatically; the project-side stub stays stable.

If `~/.dotbot/framework/` is missing when the hook runs (the user uninstalled dotbot), the stub prints `"dotbot framework not found; skipping dotbot pre-commit checks"` and exits 0 so commits don't break.

## Out of Scope

- System-wide install (`/usr/local/share/dotbot/`) for multiple OS users on one machine — defer; this PRD does per-user only.
- Network upgrade (`dotbot upgrade --from-remote https://...`) — the upgrade command re-copies from the source the install was launched from; remote upgrade is a follow-up.
- Uninstall command — manual `rm -rf ~/.dotbot/` + PATH cleanup is acceptable for now.
- Version pinning per project — every project on a machine uses the machine's installed version. Per-project version overrides are not in scope.
- Migration of existing v4 per-project installs (where each project has `.bot/core/`) — greenfield rewrite; not supported.

## Further Notes

- After this PRD lands, the per-project `.bot/` directory is small enough that there's no longer a clear cost to committing all of it. Confirm with the team whether `workspace/` is the right commit boundary (project state should be committed; `.control/` stays gitignored).
- The `dotbot` CLI wrapper is the only file outside `~/.dotbot/framework/` after install (besides PATH entries). Consider whether the wrapper should be self-updating or always re-installed via the upgrade command.
- **Open question for implementor: pre-commit hook stub pattern.** The proposed model is a small stub at `<project>/.git/hooks/pre-commit` that delegates to `~/.dotbot/framework/scripts/pre-commit.ps1`. The benefit is automatic upgrades; the cost is that the stub needs a path to the framework that may diverge if a user has multiple dotbot installs. Confirm this is the right shape vs. self-contained hooks regenerated by `dotbot init`.
- **Open question for implementor: `dotbot upgrade` and `dotbot register` commands** are my additions. Confirm before implementing — alternatives include "users re-run install.ps1" for upgrade and "users re-run dotbot init" for register-on-clone. If both alternatives are acceptable, drop the new commands to keep the CLI surface smaller.
- Open question for implementor: should `dotbot init` start the runtime automatically if it isn't running? Proposal: no — keep init synchronous and explicit; require `dotbot go` first. This avoids surprising background processes.
- Open question: where does `~/dotbot/user-settings.json` live in this layout? The legacy path was `$HOME/dotbot/`. Proposal: align with the install root and use `~/.dotbot/user-settings.json` going forward. Update settings chain prose accordingly.
