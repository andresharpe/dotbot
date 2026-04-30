# Standards

The rulebook the reviewer enforces. Every `minor` finding from the conventions agent must point to a section here. If a rule is not in this file, the agent flags it at most as a `nit`.

This file is dotbot-specific. It incorporates `CONTRIBUTING.md`, `CLAUDE.md`, the project's own `PSScriptAnalyzerSettings.psd1`, and the test-enforced output-hygiene list. Edit freely. The reviewer reloads it on every run.

## Naming

- Public function names use approved PowerShell verbs (`Get-Verb`).
- Cmdlet nouns are singular.
- Parameter names follow standard pwsh nouns where they fit: `Path`, `LiteralPath`, `Name`, `InputObject`, `Force`, `PassThru`, `WhatIf`. Project nouns from `glossary.md` are also acceptable.
- Variable names describe what they hold, not how they were computed (`$users`, not `$result`).
- Boolean parameters are `[switch]`, not `[bool]`.
- MCP tool folders are `kebab-case`, the YAML `name` is `snake_case`, and the script function is `Invoke-PascalCase`. This three-way mapping is required and enforced by the MCP server's auto-discovery.
- Branch names are `type/short-description` (`feature/`, `bugfix/`, `chore/`, `docs/` per `CONTRIBUTING.md`).

## Function shape

### Public functions (the dotbot Gallery surface)

`Invoke-Dotbot` (and the public `ClaudeCLI` exports if they ship) must:

- Have `[CmdletBinding()]`.
- Have `[OutputType()]` declaring the actual return type. Mismatched declarations are findings.
- Have comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, one `.PARAMETER` per parameter, and at least one `.EXAMPLE`.
- Use `[Parameter()]` attributes for every parameter.
- Use `[Validate*]` attributes for inputs that have constraints.
- Use a `process` block when any parameter declares `ValueFromPipeline`.
- Use `SupportsShouldProcess` for state-changing functions.
- Be listed in the module manifest's `FunctionsToExport`.

### Internal framework functions

Internal helpers under `core/`, `scripts/`, `tests/`, and `studio-ui/` are not held to the public-surface bar:

- Comment-based help is encouraged but not required.
- `[OutputType()]` is required only when the type is non-obvious or load-bearing for the caller.
- `[CmdletBinding()]` is encouraged for any function with parameters; required when using `-Verbose`, `-WhatIf`, or `Write-Error -ErrorAction Stop` discipline.

There is no `Public/`/`Private/` directory split in this codebase. Do not flag its absence.

## Error handling

- `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` at the top of every entry-point script.
- `try`/`catch` only where you can do something with the error. Empty `catch` blocks are forbidden (PSAvoidUsingEmptyCatchBlock is enabled).
- Prefer `Write-Error -ErrorAction Stop -Category <Specific> -ErrorId <Stable>` for production errors. `throw "string"` is acceptable in tests and short scripts but discouraged in framework modules.
- Do not use `-ErrorAction SilentlyContinue` without an inline comment explaining why.
- Resource cleanup goes in `finally`. Streams, file handles, and runspaces must be disposed.
- Native command exit codes must be checked. `$PSNativeCommandUseErrorActionPreference = $true` (in scope) is the preferred way; otherwise check `$LASTEXITCODE`.

## Output discipline

This is the project's loudest rule. Two layers, both enforced.

### Framework code (`core/**`, `studio-ui/StudioAPI.psm1`, MCP tools)

- **`Write-Verbose`, `Write-Warning`, `Write-Host` are banned for diagnostic output.** Use `Write-BotLog` from `core/runtime/modules/DotBotLog.psm1`.
- One output type per function. No mixed types across branches.
- Do not write to the success stream from `begin` or `end` blocks unless intended.

### Scripts (`scripts/*.ps1`, `install.ps1`)

Layer 1 Pester (`tests/Test-Structure.ps1`) enforces this list. Banned and required replacements:

| Banned | Use instead |
|--------|-------------|
| `Write-Host "text"` | Theme helper (see `CLAUDE.md` table) |
| `Write-Host "text" -ForegroundColor X` | Theme helper |
| `Write-Host ""` | `Write-BlankLine` |
| `Write-Verbose` | `Write-BotLog` (runtime) or `Write-DotbotCommand` (install) |
| `Write-Warning` | `Write-DotbotWarning` |

Theme helpers live in `scripts/Platform-Functions.psm1`: `Write-DotbotBanner`, `Write-DotbotSection`, `Write-DotbotLabel`, `Write-Status`, `Write-Success`, `Write-DotbotWarning`, `Write-DotbotError`, `Write-DotbotCommand`, `Write-BlankLine`. Exempt files: `scripts/Platform-Functions.psm1` (defines the helpers) and `install-remote.ps1` (standalone `irm | iex` with its own ANSI palette).

`Write-Progress` is acceptable for long-running visible work that has no other channel.

## Settings access

All configuration reads must go through `Get-MergedSettings` from `core/runtime/modules/SettingsLoader.psm1`.

| Banned | Replace with |
|--------|--------------|
| `Get-Content "settings/settings.default.json" \| ConvertFrom-Json` | `(Get-MergedSettings -BotRoot $botRoot).<key>` |
| `Get-Content ".control/settings.json" \| ConvertFrom-Json` | Same. |
| `foreach ($f in @($controlFile, $defaultsFile))` merge loop | Same. |
| Local `function Merge-DeepSettings` | Import from `SettingsLoader.psm1`. |

Exempt:

- Writers to the tracked baseline: `Set-AnalysisConfig`, `Set-CostConfig`, `Set-EditorConfig`, `Set-MothershipConfig`, `Set-ActiveProvider`, `scripts/workflow-add.ps1`, `scripts/workflow-remove.ps1`, `scripts/init-project.ps1`.
- Validator: `scripts/doctor.ps1`.
- Per-project workspace state that must not inherit machine-wide layers: `instance_id` in `StateBuilder.psm1`.

Module import pattern is required when a module may be loaded independently:

```powershell
if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $botRoot "core/runtime/modules/SettingsLoader.psm1") -DisableNameChecking -Global
}
```

`-Global` is required. `-Force` is banned in child modules.

## Cross-platform

The project targets pwsh 7+ on Windows, Linux, and macOS. Blockers:

- Hard-coded `\` in path strings. Use `Join-Path` or `[IO.Path]::Combine`.
- Hard-coded `/` in path strings, except for URLs.
- Use of `$env:USERPROFILE`, `$env:APPDATA`, `$env:LOCALAPPDATA` without an `$IsWindows` guard. Prefer `$HOME`.
- Use of `Get-CimInstance`, `Get-WmiObject`, registry cmdlets without `if ($IsWindows)` guard.
- Invocation of `powershell.exe` instead of `pwsh`.
- COM object creation outside `$IsWindows` blocks.

`PSUseCompatibleSyntax`, `PSUseCompatibleCmdlets`, and `PSUseCompatibleCommands` target `core-7.4-windows`, `core-7.4-linux`, and `core-7.4-macos`.

## Pipeline correctness

- Functions accepting pipeline input have a `process` block. Pipeline-aware parameters live in the `process` block, not `begin`/`end`.
- Functions emitting one or many objects use the comma trick (`,$single`) to force array context where the consumer expects an array.
- Avoid wrapping native command invocations in functions without using `| Out-Host` for streamed output - wrapping `& subprocess` in a function captures stdout into the success stream and pollutes return values.

## Concurrency

- No `$global:` or `$script:` writes from inside `ForEach-Object -Parallel`, runspace pools, or `Start-ThreadJob`.
- Shared state across threads uses `[System.Collections.Concurrent.*]` types or process-level lock files (see `core/runtime/modules/ProcessRegistry.psm1`).
- `$using:` captures must be immutable.
- The dotbot runtime supervises subprocesses via `core/runtime/launch-process.ps1`. Direct `Start-Process` from MCP tools should be avoided unless it goes through `ProcessRegistry`.

## Security defaults

- No plaintext credentials in code, parameters, or config files. The `core/hooks/verify/00-privacy-scan.ps1` gitleaks pass is a blocker. The reviewer also runs gitleaks on changed files; both must pass.
- No `Invoke-Expression` on data from a parameter, file, network, or environment. `install-remote.ps1` is the only sanctioned `iex` and only against the dotbot install URL.
- No `ConvertTo-SecureString -AsPlainText -Force` outside trusted local-only paths.
- Native command arguments must be passed in array form: `& $exe $arg1 $arg2`, never `& $exe "$concatenated"`. The dotbot codebase has had bugs here; reviewers should be strict. **InjectionHunter is the ground truth** for this rule - any finding it raises is treated as a blocker unless explicitly suppressed in this file.
- Path inputs from external data must be validated. The reference implementation is `Assert-PathWithinBounds` in `WorktreeManager.psm1` and `core/mcp/modules/PathSanitizer.psm1`.
- TLS 1.2+ only. Never disable certificate validation.
- MOTW handling on Windows: dotbot install scripts run with `Unblock-File` only against files inside the install staging directory.

### Static security tooling

Two scanners feed the security agent with deterministic findings:

- **InjectionHunter 1.0.0** (PSScriptAnalyzer custom rules). Targets injection vectors: `Invoke-Expression`, `Add-Type` of attacker-influenced source, unsafe SQL or LDAP construction, command-line concatenation, and unsafe deserialization. Reviewer findings derived from InjectionHunter must be addressed in code, not suppressed in `PSScriptAnalyzerSettings.psd1`.
- **Gitleaks 8.30.0**. Already used by `core/hooks/verify/00-privacy-scan.ps1`; the reviewer runs it on the change scope.

InjectionHunter false positives, when they happen, are usually on tests that deliberately construct unsafe input. Suppress them at the call site with `# pwsh-review:ignore InjectionRisk reason="..."`, not by excluding the rule globally.

### GitHub Actions hygiene

`actionlint 1.7.12` is part of the static-analysis pre-pass. Workflow changes under `.github/workflows/**` are reviewed against:

- Shell quoting in `run:` blocks (catches the same shellcheck issues as a local shellcheck pass).
- Action version pinning. The project pins to major versions (`@v4`, `@v5`); pinning to a SHA is encouraged for third-party actions but not required for `actions/*`.
- Missing `permissions:` blocks on workflows that modify state. Default-write permissions are forbidden.
- Expression injection via `${{ github.event.* }}` interpolated into shell. Use `env:` mappings instead.

## Testing

- Pester 5+.
- **Test files are named `Test-<Name>.ps1`** (verb-noun mirror), not the canonical Pester `<Name>.Tests.ps1`. This is intentional. Do not flag.
- Tests describe behaviour. Do not mock the function under test.
- Every public function has at least one test. Layer 2 covers framework components; layer 3 covers analysis/execution flows; layer 4 covers full E2E.
- Tests use `Should` assertions; tests without assertions are forbidden.
- Mock provider CLIs (`tests/mock-claude.ps1`, `tests/mock-codex.ps1`, `tests/mock-gemini.ps1`) are the only sanctioned way to exercise provider flows in CI without credentials.
- Test output capture: when running the full suite, capture to a file once and re-read it. Never re-run the suite to grep for different patterns. The branch-prefixed path convention is in `CLAUDE.md` and saved in user memory.
- Code coverage minimum: <!-- TODO: confirm threshold -->

## Module manifests

- `FunctionsToExport` lists the actual exports. `'*'` is forbidden.
- `RequiredModules` (when used) specifies a minimum version for every entry.
- `PowerShellVersion` is set explicitly. `dotbot.psd1` declares 7.0; CI runs 7.4.
- `CompatiblePSEditions` is set explicitly when the manifest is shipped to PSGallery. Currently `dotbot.psd1` does not declare it - that is a known TODO.
- Manifest version bumped on every change to public surface. The release workflow (`bump-release.yml`) is the canonical bump path.

## File hygiene

- **UTF-8 without BOM.** Required. The PSScriptAnalyzer rule `PSUseBOMForUnicodeEncodedFile` is project-excluded for this reason.
- LF line endings (configured via `.gitattributes`).
- No tabs in pwsh files.
- Trailing whitespace stripped.
- Maximum line length: 140 chars (`PSAvoidLongLines` rule).
- No `;` as a line terminator (`PSAvoidSemicolonsAsLineTerminators` rule).

## Documentation

- READMEs are kept current.
- `CLAUDE.md` is the source of truth for project conventions; cross-link rather than duplicate.
- Public function changes propagate to `architecture.md`'s public surface table.
- Breaking changes get a `BREAKING:` prefix in the commit message.
- PRs reference the issue they close (`Closes #N`, `Fixes #N`, `Resolves #N`). The `pr-link-check` workflow enforces this.

## Vocabulary

Issue #100 is renaming legacy terms across the codebase. Reviewers should prefer the new names in new code:

| Old | New |
|-----|-----|
| defaults | settings |
| prompts | recipes |
| adrs | decisions |
| workflow (the per-task lifecycle) | task-runner |

`tests/Test-NoLegacyVocabulary.ps1` is the moving boundary. Adding new uses of legacy terms in tracked paths is a finding.

## DOTBOT-specific architecture

### Vertical-slice boundaries

The framework is organised by capability slice (each MCP tool is its own folder under `core/mcp/tools/<name>/` with `metadata.yaml` + `script.ps1` + `test.ps1`; runtime concerns live under `core/runtime/`; UI under `core/ui/` and `studio-ui/`). New code must respect these slices:

- An MCP tool implementation does not reach across into the runtime's internal modules. If a tool needs a runtime helper, it goes through a published function or a shared module under `core/runtime/modules/`.
- Runtime modules do not import from MCP tool folders.
- Cross-slice utilities live in `core/runtime/modules/` (e.g. `SettingsLoader.psm1`, `ProcessRegistry.psm1`, `WorktreeManager.psm1`).
- New MCP tools must follow the `kebab-case` folder / `snake_case` YAML name / `Invoke-PascalCase` function naming so the auto-discovery picks them up. The mapping is enforced by `tests/Test-Components.ps1` MCP discovery tests.

Findings that flag a runtime->tool import, a tool->tool import bypassing the runtime, or a duplicated helper that already exists in `core/runtime/modules/` are `major`.

### Runtime CLI output discipline (terminal theme)

Runtime CLI output (control-panel banners, status lines, dashboard updates) goes through `core/runtime/modules/DotBotTheme.psm1` helpers (`Write-Status`, `Write-Banner`, `Write-Card`, `Write-Header`, etc.). Do not bypass the theme module with raw `Write-Host -ForegroundColor` calls inside `core/runtime/`. The theme module reads `theme-config.json` for the user's preset and respects the CRT/amber aesthetic.

This is parallel to the `scripts/Platform-Functions.psm1` rule for installer / script output, but applies to long-running runtime processes (the supervisor, the dashboard renderer, MCP server start-up banner). Findings that introduce raw `Write-Host` for CLI output in `core/runtime/` are `minor`.

## DOTBOT-specific security

### Audit-archive redaction must run before write

Any code that writes audit / session archives (e.g. anything that captures tool I/O, Claude prompts, or session transcripts to disk for later review) must redact secrets **before** the write, not after. A two-step "write then redact" pattern leaks plaintext to the disk between the two steps and survives if the redaction step crashes. Findings that introduce a write-then-scrub pattern are `blocker`.

The reference is the existing `core/hooks/verify/00-privacy-scan.ps1` pre-commit gate plus `Assert-PathWithinBounds` in `core/runtime/modules/WorktreeManager.psm1` — both run **before** state is committed to disk. New audit-archive code must follow the same ordering.

### Steering / whisper channel: untrusted input

`core/hooks/scripts/steering.ps1` and `core/mcp/tools/steering-heartbeat/` accept operator messages that get fed to a running session. Any new code that:

- Reads a `*.whisper.jsonl` file and feeds the contents into a Claude prompt
- Accepts a steering message via stdin / parameter and forwards it to a tool

must treat the message body as untrusted input. In particular, the body must not be embedded into a prompt without escaping, must not be `Invoke-Expression`'d, and must not be used to construct a path. Findings that route a whisper message into a prompt verbatim, into `iex`, or into a path-building string concatenation are `blocker`.

### MCP tool path-traversal allowlist

MCP tools that accept path-shaped parameters (`plan-get`, `plan-update`, `task-mark-done`, anything else that resolves an ID to a path) must validate the resolved path against an allowlist root before opening it. The reference is `Assert-PathWithinBounds` in `core/runtime/modules/WorktreeManager.psm1`:

```powershell
Assert-PathWithinBounds -Path $resolved -ExpectedRoot $projectRoot
```

Findings that resolve a tool argument to a path and then `Get-Content` / `Set-Content` / `Remove-Item` it without the bounds check are `blocker`. The allowlist itself (which paths are valid roots) is per-tool — for plan / task tools it's the dotbot workspace under the project root.

### Tool-name allowlist before dispatch

The MCP server dispatches incoming `tools/call` requests to tool functions by name. The canonical pattern (`core/mcp/dotbot-mcp.ps1`) validates the name against the discovered tool registry **before** constructing the function name and calling it:

```powershell
if (-not $tools.ContainsKey($Name)) {
    throw "Unknown tool: $Name"
}
```

Any new dispatch surface that takes a name from external input and calls a function (e.g. via `& $functionName`) must validate against an allowlist first. The pattern is captured in `.pwsh-review/patterns/pattern-allowlist-dispatch.ps1`. Findings that construct and invoke a function name from external input without an allowlist check are `blocker`.

## DOTBOT web UI (`core/ui/static/`, `studio-ui/`)

### HTML escaper

The canonical HTML escaper is `escapeHtml(value)` in `core/ui/static/modules/utils.js`. Any `innerHTML`, `insertAdjacentHTML`, `outerHTML`, or `document.write` assignment that interpolates a dynamic value (anything not a string literal) must route the dynamic value through `escapeHtml(...)` before it lands in the DOM. The js-content-agent's `PWSH-JS-008` rule cites this file and this function name; findings without the escaper are `blocker` (XSS).

Findings that redefine `escapeHtml` locally instead of importing from `utils.js` are `minor` — the duplicate is harmless but drifts over time.

### Module layout

Web-UI JavaScript follows the existing pattern: vanilla JS module under `core/ui/static/modules/` (or `studio-ui/static/modules/`), loaded by `app.js` (or `scope.js`). New JS modules:

- Live in the `modules/` directory, not at the static root.
- Export named functions; avoid default exports unless the consumer is also default-importing.
- Do not redefine utility functions already in `utils.js` (escapeHtml, debounce, formatBytes, etc.).
- Do not write to `window.*` for cross-module communication. Use module imports.

Findings that put a new JS file at the static root, redefine a `utils.js` function, or wire cross-module state via `window.X` are `minor`.

## Deviations

Documented project-specific deviations from generic pwsh standards:

- `PSAvoidUsingWriteHost` is excluded - acceptable in CLI output and theme helpers.
- `PSUseShouldProcessForStateChangingFunctions` is excluded - too noisy on internal scripts.
- `PSAvoidUsingPositionalParameters` is excluded - too noisy for existing code.
- `PSUseBOMForUnicodeEncodedFile` is excluded - BOM-less UTF-8 is intentional.
- `PSAvoidGlobalVars` is excluded - `$global:DotbotProjectRoot` is architectural.
- `PSAvoidAssignmentToAutomaticVariable` is excluded - `$event` is used intentionally in stream processing.
- `PSReviewUnusedParameter` is excluded - some params reserved for future use.
- `PSUseDeclaredVarsMoreThanAssignments` is excluded - variables used in dynamic scopes.
