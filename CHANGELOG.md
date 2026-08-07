# Changelog

All notable changes to dotbot are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [4.0.3] - 2026-07-16

### Added

### Changed

### Fixed

### Removed

## [4.0.2] - 2026-07-09

### Added

### Changed

### Fixed

### Removed

## [4.0.1] - 2026-07-02

### Added
- **`bootstrap.ps1`** at the repo root — the one-time install step. Drops the `bin/shim/dotbot*` PATH shim into `~/.local/bin` (Linux/macOS) or `%LOCALAPPDATA%\Microsoft\WindowsApps` (Windows). Refuses PowerShell 5.1; never sets `$env:DOTBOT_HOME` for the user (design decision D4). Honours `-ShimDir` and `-Force`.
- **`dotbot status`** subcommand reporting resolved `DOTBOT_HOME`, framework branch + short SHA + dirty flag, version, user-settings path, and the active project's workflow / provider / stacks. `--json` emits a stable shape for CI scripts and the dashboard.
- **UI framework banner** in the dashboard header — surfaces the active `DOTBOT_HOME` plus framework branch/SHA/dirty, with an amber warning state when the checkout is dirty or off `main`/`master`.
- **`MIGRATING.md`** at the repo root walks v3 projects through the rewrite (shim install, project `.bot/` rewrite, `.mcp.json` repointing, user-settings move, settings layer reshuffle, retired-entry-point cheat sheet).
- **Active-stack hook chain** — `ContentResolver` now folds three tiers in order (framework → active stacks via `extends` chain in `.control/settings.json` → project), exposed via `Get-DotbotActiveStackChain`.

### Changed
- **`dotbot init` is now a sparse project bootstrap.** A fresh `.bot/` contains only `workspace/` (seeded from `<DOTBOT_HOME>/content/workspace-template/`) and `.gitignore`. Framework content stays in `$env:DOTBOT_HOME` and is resolved lazily; `-Workflow X` / `-Stack Y` materialise project-tier directories under `.bot/content/` only when the source ships an `overrides/` subtree (registry items always materialise). Init hard-errors when `DOTBOT_HOME` is unset.
- **`Get-MergedSettings` Layer 1 source moved** from `<BotRoot>/settings/settings.default.json` (which init no longer creates) to `<DOTBOT_HOME>/content/settings/settings.default.json`. A new tracked project override layer at `<BotRoot>/content/settings/settings.default.json` sits between framework defaults and user-settings.
- **Workspace `instance_id` moved** out of `settings.default.json` into `.bot/.control/settings.json`, lazy-created by the runtime on first start. UI writers already wrote to `.control/settings.json`, so no operator action is required for existing projects.
- **`workflow add` / `workflow remove`** record / clear the active workflow in `.bot/.control/settings.json`. No more `installed_workflows` baseline writes, `.mcp.json` merges, `.env.local` scaffolding, or `domain.task_categories` merges into the framework defaults file.
- **CLI scripts (`runtime-start`, `runtime-status`, `tasks-run`, `workflow-list`, `workflow-run`, `workflow-scaffold`)** import runtime modules from `<DOTBOT_HOME>/src/runtime/Modules/` directly. The old walk-up-to-find-a-fallback path is gone.
- **MCP server discovery** walks both `tools/` (new layout) and `systems/mcp/tools/` (legacy) under each workflow source — the pre-v4 init normalised the latter to the former on copy, and the resolver now handles it directly.
- **README, AGENTS.md / CLAUDE.md** rewritten for the shim-only install model. Quick Start is `git clone` + `pwsh bootstrap.ps1` + `$env:DOTBOT_HOME = $PWD`. AGENTS.md "Dev Cycle" drops the reinstall step (DOTBOT_HOME tracks the checkout live). Architecture sections describe the layered content resolver and four-layer settings chain.

### Removed
- **`install.ps1`, `install-remote.ps1`** — the copy-based installers. v4 only ships a PATH shim; the framework is a git checkout you point `$env:DOTBOT_HOME` at.
- **`dotbot.psm1`, `dotbot.psd1`** — the PowerShell Gallery entry point. `Install-Module Dotbot` retired alongside `install.ps1`.
- **`src/cli/install-global.ps1`** — the deploy-to-`~/dotbot` logic that the retired installers called.
- **`src/init.ps1`, `src/go.ps1`** — IDE-integration setup and UI launcher copies that `dotbot init` used to drop into `.bot/`. Their replacement is the `dotbot runtime-start` subcommand backed by `src/cli/runtime-start.ps1`.
- **`tests/Test-GoScript.ps1`** — its end-to-end launch test was already skipped pending the `dotbot go` rehoming.
- **`.bot/.manifest.json` generation + pre-commit hook generation + framework-paths protection** — Phase 4 removed the framework copy from `.bot/`, so the integrity gates that guarded those copies became inert.
- **`.bot/src/`, `.bot/content/`, `.bot/settings/`, `.bot/recipes/`, `.bot/hooks/`** copies. They were caches of framework code that drifted; the runtime resolver now reads them lazily from `DOTBOT_HOME`.
- **`.codex/config.toml`, `.gemini/settings.json`** writes from `dotbot init`. Provider MCP configuration is the user's to manage; the `dotbot mcp link` subcommand to wire it up automatically is on the roadmap (Phase 8 in `PLAN.md`).
- **`Install-Module Dotbot` / `irm install-remote.ps1 | iex` / `pwsh install.ps1` / `dotbot update` / `.bot\go.ps1` / `.bot\init.ps1`** as entry points. See `MIGRATING.md` §7 for the cheat-sheet.
- **`docs/whitepapers/UI-AND-DOMAIN-MODEL-WHITEPAPER-v2.md`** — described the v3 launcher (`.bot\go.ps1`) and is fully superseded by `MIGRATING.md` plus the rewritten README/AGENTS.md.

### Migration
- Existing v3 projects need the rewrite documented in `MIGRATING.md`: archive `~/dotbot`, clone afresh, run `bootstrap.ps1`, set `DOTBOT_HOME`, then `git rm` the stale `.bot/src` + `.bot/content` + `.bot/settings` + `.bot/recipes` + `.bot/hooks` + `.bot/.manifest.json` + `.bot/go.ps1` + `.bot/init.ps1` per project. The `~/dotbot/user-settings.json → ~/.config/dotbot/user-settings.json` move is automatic (idempotent migration on first `Get-MergedSettings` call).

### CI
- **Release pipeline rewired to the shim-only model.** `test.json` drops the `pwsh install.ps1` step from all jobs; `release.json` builds the archive by `rsync`-ing the working tree (sans `.git/`, `node_modules/`, `.bot/`, staging + archive outputs), overlays the pre-built `src/studio-ui/static/`, and uploads the GitHub release with v4 install commands in the notes. The PSGallery publish job is deleted. `bump-release.json` drops the `dotbot.psd1` `ModuleVersion` bump — `version.json` is the only bump artefact now.
- **Theme-hygiene scanner** now targets `bootstrap.ps1` instead of the retired `install.ps1`; `src/cli/Platform-Functions.psm1` is the sole exempt file.
- Layer 1 has a new BOOTSTRAP.PS1 contract block that drives `bootstrap.ps1` into a temp `-ShimDir` and asserts the PS 7 guard, shim source, platform default targets, and the "never `SetEnvironmentVariable(...DOTBOT_HOME...)`" rule (D4).
- Layer 2 has a new "Phase 4: dotbot init footprint" block pinning the strict init contract (`.bot/` children == `{.gitignore, workspace}`; nothing outside `.bot/` mutated; project tier created only when overrides exist) and a "Phase 5: `dotbot status --json` shape" block pinning the JSON contract that the UI banner + CI scripts depend on.

### Kickstart vocabulary rename (previously documented)
- The kickstart vocabulary rename is locked in across the codebase. CSS classes, JS function names, modal IDs, the `kickstart_*` keys on `/api/info` (now `workflow_*`), the `Get-KickstartStatus` PowerShell function (now `Get-WorkflowStatus`), workflow JSON commit-message templates (`chore(kickstart):` → `chore(workflow):`), and the `dotbot-kickstart` generator string in `task-groups.json` and `roadmap-overview.md` front matter (now `dotbot-task-runner`) all use the new names.
- User-visible: the project-launch button label changed from `KICKSTART PROJECT` to `LAUNCH PROJECT`. The `Kickstart` button text in the preflight modal changed to `Launch`. The Jira interview phase title changed from `Kickstart Interview (Multi-Repo)` to `Project Interview (Multi-Repo)`. New commit messages use `chore(workflow):` instead of `chore(kickstart):`.
- The `kickstart-via-jira`, `kickstart-via-pr`, `kickstart-via-repo`, and `kickstart-from-scratch` workflow aliases in `dotbot init -Workflow` are gone. Use the canonical `start-from-jira`, `start-from-pr`, `start-from-repo`, and `start-from-prompt` names.
- The `tests/Test-NoKickstartReferences.ps1` warning gate is now `tests/Test-NoLegacyVocabulary.ps1`, a hard Layer 1 fail. Any `kickstart` reference outside `ideas/` and the gate file itself fails the build.
