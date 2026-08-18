# Changelog

All notable changes to dotbot are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

### Changed

### Fixed
- **A failed task no longer discards the commits the agent already made (#683).** All three task-failure paths in `Invoke-WorkflowProcess.ps1` removed the worktree *and* force-deleted the task branch, leaving committed work reachable only as a dangling git object that the next `git gc` destroys. Executor-dispatch failure, provider/prompt failure, and an agent calling `task_set_status(failed)` (which lands in the terminal-state arm, since there is no `failed/` bucket for `Get-TaskTerminalState`) now all remove only the worktree and report the preserved branch plus its tip SHA (`Branch task/… preserved at <sha> — inspect with: git log task/…`). The genuinely-abandoned terminal states (`skipped`/`cancelled`/`split`) still delete the branch, and uncommitted worktree changes are still discarded.
- **A run no longer leaves an empty, unreapable `workflow/*` integration branch (#683).** The integration branch was created before any task ran and pushed with `-u` unconditionally, so a run whose output is gitignored (or which completed zero tasks) published a branch whose PR would be empty — and pushing it is exactly what made `dotbot prune-branches` skip it by default. Run completion now counts `rev-list --count <base>..<integration>` and, when it is zero, skips the push and deletes the branch (with the safe `-d`) after restoring the base checkout — unless a retained worktree still records it as its `base_branch`, in which case it is kept locally so a parked or escalated task can still merge into it. Branches that carry commits are pushed and announced exactly as before.
- **`dotbot prune-branches` candidate list** no longer glues the branch name to the timestamp, and renders the date culture-invariantly (#683).
- **Kebab-case CLI flags bind again (#684).** `bin/dotbot.ps1` used the raw flag text as the splat key, so every hyphenated flag raised a `ParameterBindingException` from inside the dispatcher: `--older-than`, `--poll-interval-ms`, `--bot-root`, `--mothership-api-key`, `--no-auto-runtime` and `--no-runtime` all failed. A single `ConvertTo-DotbotParameterName` helper now normalises `--older-than` → `OlderThan` at the five places the dispatcher derives a splat key. Unhyphenated flags keep their existing key, and `--mothership-key` keeps working through a compatibility alias on `serve.ps1`.
- **`dotbot doctor` no longer reports PASS for a directory it never scanned (#684).** `doctor.ps1` was a *simple* script, so `--bot-root <path>` landed in `$args` and was silently dropped. It, `tasks-run.ps1` and `tasks-stop.ps1` are now advanced scripts that reject unknown flags, and `dotbot tasks run` passes its flags through instead of discarding them.
- **Every CLI error path now exits non-zero (#684).** Unknown verb, missing required argument, parameter-binding failure and `ValidateSet`/`ValidateRange` violations all exited 0, so no CI step could detect a mistyped dotbot command. Binding and validation failures are reported through the theme helpers instead of a raw PowerShell stack frame, the usage / not-found paths for `run`, `workflow`, `tasks`, `install`, `registry`, `init`, `go`, `studio` and `resume` exit 1, and `init`, `workflow`, `registry`, `install`, `tasks`, `status`, `serve`, `prune-branches` and `studio` now propagate their child script's exit code (previously only `doctor` and a valid `run` did, so `dotbot init` returned 0 from a non-git directory). `logs` and `runtime-status` deliberately do not propagate: their scripts use `exit 1` for the ordinary "nothing to show" states ("Not running", "No activity log yet"), so propagating would make two display commands report failure on a freshly initialised project. `dotbot install skill <name> --unknown-flag` is also rejected rather than dropped, because the dispatcher's unknown-flag fall-through reached only the runtime splat. `dotbot help` still exits 0.
- **`dotbot help` matches reality (#684):** the non-existent `install content` is replaced by the real `install skill` spelling, `workflow scaffold` is documented, and the `workflow` usage line advertises `--force` rather than `--Force`.
- **`dotbot studio` is reachable again (#684).** The verb resolved `<DOTBOT_HOME>/studio-ui`, but the studio moved to `src/studio-ui/` in v4; the studio's own `server.ps1` and `go.ps1` also still imported `Dotbot.Core` from the retired `src/core/` path. Both are corrected, and the already-running branch calls a theme helper the dispatcher actually imports. The studio still needs its Vite build (`src/studio-ui/static/`, gitignored) to serve.
- **The dashboard no longer fetches webfonts from `fonts.googleapis.com` (#685).** `src/ui/static/css/base.css` `@import`ed Google Fonts, so a tool that otherwise runs entirely on localhost made an outbound request on every page load and silently fell back to system fonts offline. Inter and JetBrains Mono (both OFL-1.1) are now self-hosted as variable woff2 under `src/ui/static/fonts/` — latin and latin-ext subsets, matching the `unicode-range` splits the CDN stylesheet used, so accented text keeps its typeface — and the UI server serves `.woff2`/`.woff` with the correct MIME type.

- **Task merges no longer target a stale `base_branch`.** `Complete-TaskWorktree` took its integration
  target from the value `worktree-map.json` recorded when the worktree was created and never reconciled
  it with the branch the main checkout was on. With a clean tree it silently squash-merged the task into
  that recorded branch — usually the trunk — and reported plain success; with a dirty tracked file under
  `.bot/workspace/decisions/` it failed with `Failed to checkout <base> … (currently on: <branch>)` and
  parked the run. The target is now resolved by precedence: an explicit `-BaseBranch` from the caller (a
  workflow run passes its integration branch), then a configured `git.base_branch`, then the recorded
  value when it matches the checkout, then the checked-out branch — adopted, reconciled back into the
  map, and named in the result message. `task/*` branches and detached HEADs are never adopted.
- **The pre-merge stash no longer excludes `.bot/workspace/decisions/`.** That tree is tracked and is
  committed by the same function, but — unlike `.bot/workspace/tasks/` — it was never scrubbed or backed
  up, so a dirty file there blocked the very checkout the stash exists to enable.
- **The pre-merge stash is popped even when `git stash push` exits non-zero.** `git stash push -u` can
  stash successfully and still exit 1 over an advisory (`The following paths are ignored by one of your
  .gitignore files: .bot/workspace/tasks`), which made dotbot skip the pop and silently park the
  operator's uncommitted work in a stash. Stash detection now compares `refs/stash` before and after.
- **`Assert-OnBaseBranch` reports why a checkout failed and can honour `git.base_branch`.** It discarded
  git's stderr, so every blocker — a dirty tracked file, a branch held by another linked worktree, a
  file lock — produced the same unactionable message. It also had no `-BotRoot` parameter, so its
  no-`-BranchName` fallback could only ever resolve `main`/`master`; the three cleanup call sites in
  `Invoke-WorkflowProcess.ps1` used that fallback and yanked the working copy off a configured base
  branch on any failed or skipped task.

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
