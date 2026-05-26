# Migrating to dotbot v4

v4 reshapes how dotbot is installed and how a project's `.bot/`
relates to the framework. This guide walks an existing v3 project
through the rewrite. The short version:

> **v3:** `install.ps1` copied the entire framework into `~/dotbot`,
> and `dotbot init` mirrored most of it into your project's `.bot/`.
> Two long-lived copies, both subject to drift.
>
> **v4:** the only machine-wide artefact is a ~30-line PATH shim
> (`bin/shim/dotbot`). The framework lives in a git checkout you
> point `$env:DOTBOT_HOME` at. `dotbot init` only writes
> `.bot/workspace/` and `.bot/.gitignore`; the runtime resolves
> everything else from `DOTBOT_HOME` via the layered content
> resolver.

If you only need the new install commands, [README.md → Quick Start](README.md#quick-start) is enough. Read on if you have an existing v3 project to migrate or a v3 install on the machine.

---

## 1. Replace `~/dotbot` with a tracked checkout

v3 installed via `pwsh install.ps1` (or `Install-Module Dotbot`,
`irm install-remote.ps1 | iex`). All three are retired in v4.

```powershell
# Optional: archive the v3 install first
mv ~/dotbot ~/dotbot.v3.backup

# Clone the new checkout — keep this directory; DOTBOT_HOME points at it.
git clone https://github.com/andresharpe/dotbot ~/dotbot
pwsh ~/dotbot/bootstrap.ps1
```

`bootstrap.ps1` drops `bin/shim/dotbot` (and `dotbot.cmd` / `dotbot.ps1` on Windows) into a PATH-visible directory. It refuses to run on PowerShell 5.1 and never writes `DOTBOT_HOME` for you — that's deliberate (design decision D4 in `PLAN.md`).

Point `DOTBOT_HOME` at the checkout and persist it:

```powershell
# PowerShell / Windows (one session)
$env:DOTBOT_HOME = "$HOME/dotbot"
# Persist for the User scope on Windows:
setx DOTBOT_HOME "$HOME/dotbot"

# bash / zsh / sh — add to ~/.zshrc, ~/.bashrc, or ~/.profile
export DOTBOT_HOME="$HOME/dotbot"
```

Confirm:

```powershell
dotbot status
```

That prints the resolved `DOTBOT_HOME`, the framework branch / SHA / dirty flag, the user-settings path, and the active project's workflow + provider. If `DOTBOT_HOME` is wrong, the shim hard-errors with a remediation message — there is no fallback in v4.

You can keep several checkouts on the same machine and flip between them by changing `DOTBOT_HOME`. The shim does the routing; the framework code is whichever tree you pointed at.

---

## 2. Migrate an existing project's `.bot/`

### Stale `.bot/src/` snapshot

v3's `dotbot init` (and `dotbot init --force`) copied `src/runtime/`, `src/mcp/`, `src/ui/`, `src/cli/`, and `src/hooks/` into `.bot/src/` inside every project. That snapshot is frozen at the moment the project was last init'd — it is not a "live" framework view.

After upgrading to v4 the snapshot becomes drift: the runtime resolver looks at `DOTBOT_HOME` first and only falls back to project-tier files for *overrides*. A `.bot/src/` snapshot is not an override; it is dead code your repo still ships.

**Fix once per project:**

```powershell
cd <your-project>
git rm -r .bot/src .bot/content .bot/settings .bot/recipes .bot/hooks .bot/.manifest.json .bot/go.ps1 .bot/init.ps1 .bot/README.md 2>$null
# Re-init to seed the v4 workspace + .gitignore (workspace data is preserved
# when .bot/ already exists; only the gitignore is rewritten).
dotbot init -Force
git add .bot/
git commit -m "chore: migrate .bot/ to v4 sparse layout"
```

If you previously customised something under `.bot/src/`, `.bot/content/`, or `.bot/hooks/`, port the customisations to the project-tier override locations *before* the `git rm` step:

- Agent / skill / prompt / recipe / workflow / stack overrides → `<BotRoot>/content/<type>/<name>/`
- Hook overrides → `<BotRoot>/hooks/<verify|dev|scripts>/`
- Settings overrides → `<BotRoot>/content/settings/settings.default.json` (tracked) or `<BotRoot>/.control/settings.json` (gitignored)

The resolver merges them over `DOTBOT_HOME`'s defaults; framework-only files still run.

### Pre-commit hook and `.bot/.manifest.json`

v3 init dropped a pre-commit hook into `.git/hooks/pre-commit` plus a SHA256 manifest at `.bot/.manifest.json` that guarded `.bot/src/`, `.bot/content/`, and friends. v4 does not install either, because the files they protected are no longer in `.bot/`.

If your `.git/hooks/pre-commit` was the dotbot-generated one (it carries a `# dotbot:` marker on its first comment block), delete it:

```powershell
rm .git/hooks/pre-commit         # if dotbot-generated
git rm .bot/.manifest.json 2>$null
```

Your own pre-commit hooks (gitleaks, prettier, etc.) are unaffected — only the dotbot-generated one is retired.

---

## 3. Rewrite `.mcp.json` for v4

If you registered the dotbot MCP server in Claude Code / Codex / Gemini, the registration points at the old in-project copy (`.bot/src/mcp/dotbot-mcp.ps1` or, for very old installs, `.bot/systems/mcp/dotbot-mcp.ps1`). Those files are gone after the migration above.

The v4 MCP server lives in `DOTBOT_HOME`. Update each MCP host's config:

```json
{
  "mcpServers": {
    "dotbot": {
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "<DOTBOT_HOME>/src/mcp/dotbot-mcp.ps1"
      ]
    }
  }
}
```

Substitute the absolute path (`$env:DOTBOT_HOME` expansion does not happen inside the MCP host's JSON). On Windows: `C:\Users\<you>\dotbot\src\mcp\dotbot-mcp.ps1`.

> An opt-in `dotbot mcp link` subcommand that wires this up across the
> common MCP hosts is on the roadmap — see `PLAN.md` Phase 8.

If you wired up the older `.codex/config.toml` or `.gemini/settings.json` files that v3 `dotbot init` dropped into project roots, drop the dotbot blocks from them (or repoint them at `<DOTBOT_HOME>/src/mcp/dotbot-mcp.ps1`). v4 `dotbot init` no longer touches those files — anything you keep is yours to maintain.

---

## 4. `~/dotbot/user-settings.json` moves

Phase 3 of the rewrite decoupled the user-settings layer from `DOTBOT_HOME` so your provider preferences, API keys, and editor choices survive `DOTBOT_HOME` swaps. The new location:

- **Linux / macOS:** `~/.config/dotbot/user-settings.json` (honours `$XDG_CONFIG_HOME`)
- **Windows:** `%APPDATA%\dotbot\user-settings.json`

A one-time migration runs on the first `Get-MergedSettings` call after the upgrade: if `<DOTBOT_HOME>/user-settings.json` exists and the new path doesn't, dotbot moves the file and logs the move. The migration is idempotent and safe to re-run — running it twice in the same process is a flag-guarded no-op.

You do not need to do anything manually. If you want to confirm:

```powershell
dotbot status            # prints the resolved user-settings path
dotbot status --json     # JSON shape: { "user_settings_path": ..., "user_settings_exists": true|false }
```

If you have multiple legacy `~/dotbot*/user-settings.json` files across machines, only the one in the currently-active `DOTBOT_HOME` migrates; the rest stay where they are until you point `DOTBOT_HOME` at them.

---

## 5. Settings layer chain reshuffle

v4 has four merged settings layers (low → high):

1. `<DOTBOT_HOME>/content/settings/settings.default.json` — framework defaults
2. `<BotRoot>/content/settings/settings.default.json` — project-tier override, tracked in git, optional
3. `Get-DotbotUserSettingsPath` (`~/.config/dotbot/user-settings.json` etc.) — machine-local user prefs
4. `<BotRoot>/.control/settings.json` — per-project gitignored state (workflow + stacks selection, `instance_id`, UI writer overrides)

Two changes from v3 are worth flagging:

- **Layer 1 moved.** v3 read framework defaults from `<BotRoot>/settings/settings.default.json`. v4 reads them from DOTBOT_HOME's `content/settings/settings.default.json`. The legacy file no longer exists after the migration in §2. If you have a custom default, copy it into `<BotRoot>/content/settings/settings.default.json` (Layer 2) — it'll deep-merge over DOTBOT_HOME's defaults.
- **`instance_id` moved.** The per-project workspace identity used to live in `<BotRoot>/settings/settings.default.json`. v4 lazy-creates it in `<BotRoot>/.control/settings.json` on first runtime start. Existing projects get a fresh `instance_id` after the migration; if you specifically need the old one, copy the value from your archived `.bot/settings/settings.default.json` into `.control/settings.json` before launching the runtime.

UI writers (`Set-AnalysisConfig`, `Set-CostConfig`, `Set-EditorConfig`, `Set-MothershipConfig`, `Set-ActiveProvider`) already wrote to `.control/settings.json` in v3, so any UI-driven config carries over.

---

## 6. Upgrading the framework

Once you're on v4, upgrading is `git pull` inside the DOTBOT_HOME checkout:

```powershell
cd $env:DOTBOT_HOME
git pull
```

No reinstall step, no test framework rebuild — `dotbot status` reflects the new commit immediately. The web dashboard's header surfaces the framework branch + short SHA + dirty flag so you can see at a glance which tree the UI is bound to.

---

## 7. Retired entry points (quick reference)

| v3                                                            | v4                                                            |
|---------------------------------------------------------------|---------------------------------------------------------------|
| `pwsh install.ps1`                                            | `pwsh bootstrap.ps1`                                          |
| `irm .../install-remote.ps1 \| iex`                           | `git clone ... && pwsh bootstrap.ps1`                         |
| `Install-Module Dotbot`                                       | `git clone ... && pwsh bootstrap.ps1`                         |
| `dotbot update`                                               | `git pull` inside DOTBOT_HOME                                 |
| `.bot/go.ps1`                                                 | `dotbot runtime-start`                                        |
| `.bot/init.ps1`                                               | (retired — IDE integration moves to opt-in commands later)    |
| `.bot/src/...`, `.bot/content/...`                            | `<DOTBOT_HOME>/src/...`, `<DOTBOT_HOME>/content/...`          |
| `.bot/.manifest.json` + dotbot pre-commit hook                | (retired — framework no longer lives in `.bot/`)              |
| `<DOTBOT_HOME>/user-settings.json`                            | `~/.config/dotbot/user-settings.json` (or `%APPDATA%\dotbot`) |
