---
name: dotbot-code-review
description: Performs rigorous, multi-agent code review on changes to the DOTBOT autonomous coding framework (github.com/andresharpe/dotbot). Use whenever the user asks to review, audit, or critique a PR, diff, commit range, or staged changes in the dotbot working tree. Adapts Anthropic's official code-review plugin pattern (parallel reviewers + confidence scoring) to DOTBOT's conventions: vertical slice architecture, secret redaction in .claude-audit/, PowerShell theme/CLI layer, Serilog/Polly/EF Core, and the CRT/amber terminal aesthetic. Not for general code review of unrelated repos.
---

# dotbot-code-review

Adapted from `anthropics/claude-code/plugins/code-review` (Boris Cherny). Same multi-agent + confidence-scoring backbone, retuned for DOTBOT.

## Required model

This skill requires **Claude Opus 4** (`claude-opus-4-20250514`). The multi-agent review pipeline, confidence scoring, and security analysis demand the strongest reasoning model available. Do not run with Sonnet or Haiku — downgraded models produce unreliable confidence scores and miss subtle security issues.

## When to run

Trigger on phrases like: "review this PR", "code review", "audit this diff", "critique these changes", "look over my dotbot work", or any explicit reference to a dotbot branch, PR number, or commit range. Do **not** run on unrelated repos.

## Inputs to establish first

Before doing anything, confirm scope. Ask only if unclear:

1. **What's being reviewed** — PR number, branch, commit range, or `git diff` against a base. Prefer a real diff over loose files.
2. **Base branch** — usually `main`. Pull it if not local.
3. **PR title + description** — fetch via `gh pr view <n>` if a PR. Use for intent context in every agent prompt below.

If reviewing a local working tree, run `git status` and `git diff <base>...HEAD` and treat that as the diff.

## Procedure

### Step 1 — Locate conventions
Enumerate the relevant `CLAUDE.md` / `AGENTS.md` / `README.md` / `CONTRIBUTING.md` files. For any changed file, only `CLAUDE.md` files at that path or a parent path apply. Return paths only, not contents — load contents per-agent on demand.

### Step 1b — Review existing automated PR comments

Before launching review agents, fetch and analyse any existing review comments left by other automated agents on this PR. This avoids duplicate findings and lets dotbot-code-review build on prior analysis.

**Fetch comments:**
```pwsh
# Get all review comments on the PR
gh api "repos/{owner}/{repo}/pulls/{pr_number}/comments" --paginate | ConvertFrom-Json

# Get all reviews (top-level review bodies)
gh api "repos/{owner}/{repo}/pulls/{pr_number}/reviews" --paginate | ConvertFrom-Json

# Get review threads with resolution status (GraphQL — gh pr view lacks reviewThreads)
gh api graphql -f query='{ repository(owner:"{owner}", name:"{repo}") { pullRequest(number:{pr_number}) { reviewThreads(first:100) { nodes { isResolved comments(first:1) { nodes { path line body author { login } } } } } } } }'
```

**Identify automated reviewers:**
Filter comments by author login matching known bot patterns:
- Any login ending with `[bot]` (e.g. `github-actions[bot]`, `copilot[bot]`, `codex[bot]`, `claude[bot]`, `coderabbitai[bot]`)
- Known service accounts: `dependabot`, `renovate`, `sonarcloud`, `codecov`

**Extract per-comment:**
- `author` — the bot or service login
- `path` — file the comment is attached to
- `line` / `start_line` — line range in the diff
- `body` — the comment text
- `isResolved` — whether the thread has been resolved (from GraphQL `reviewThreads` query)

**Build prior context document:**
Compile unresolved automated findings into a structured summary to feed into each review agent (Step 2):

```
## Prior Automated Review Comments (unresolved)

### @coderabbitai[bot] — src/Services/TaskRunner.cs:L42-L48
Missing null check on `taskContext.Session` before accessing properties.
Status: unresolved

### @copilot[bot] — scripts/deploy.ps1:L15
Hardcoded path should use `$env:DOTBOT_HOME` instead.
Status: unresolved
```

If no automated comments exist, note: "No prior automated reviews found on this PR."

### Step 2 — Launch 5 parallel review agents

Each agent gets the diff, the PR title + description, the relevant convention file paths, **and the prior automated review summary from Step 1b**. Each returns a list of `{file, start_line, end_line, description, reason, suggested_code}` issues.

Agents must:
- **Not duplicate** issues already flagged by a prior automated reviewer (skip if same file + overlapping line range + same category of issue)
- **Confirm or dispute** prior findings when the agent has a strong opinion — reference the prior comment: "Confirming @coderabbitai's finding on L42" or "Disagree with @copilot — this is intentional because..."

- **Agent 1 — Convention compliance (A).** Audit diff against `CLAUDE.md`/`AGENTS.md` rules. Quote the exact rule being broken.
- **Agent 2 — Convention compliance (B).** Same brief, independent run. Redundancy catches misses.
- **Agent 3 — Bug hunter.** Diff-only. Flag only what is verifiable inside the diff. No nitpicks. Apply the relevant subsection based on file extensions in the diff:

  **General (all languages):**
  - Logic errors, off-by-ones, broken contracts, race conditions.
  - Identifier/key collision: when code normalizes input (strips extensions, lowercases, trims prefixes) to derive a lookup key, verify that distinct inputs cannot map to the same key. Example: stripping both `.md` and `.json` extensions makes `foo.md` and `foo.json` collide on key `foo`.
  - Silent data loss from truncation, rounding, or encoding conversions.
  - **Alias/normalization consistency:** when code resolves an alias or fallback (e.g., a default name, a slug, a shortened ID), verify that the resolved canonical value is propagated to ALL downstream consumers. A common bug: the lookup variable is corrected (e.g., `$dir = $fallbackDir`) but the name/key variable (e.g., `$name`) is not updated, causing downstream operations (task creation, filtering, stop signals) to use the alias instead of the canonical value.
  - **Write-without-read:** when code writes data to a file path (config, prompt, state), verify that a consumer exists that reads from that exact path. Check the existing codebase for the canonical location of that data — if another path is already established (e.g., `.bot/.control/launchers/kickstart-prompt.txt` vs `workspace/product/kickstart-prompt.txt`), the new write may be orphaned.
  - **Cross-platform consistency:** dotbot runs on Windows, macOS, and Linux. When the diff uses platform-specific APIs, check that they work correctly on all three. Common traps: `[System.Environment]::UserDomainName` returns hostname (not domain) on non-Windows; `/proc/<pid>/` does not exist on macOS; `Join-Path` with embedded forward slashes produces mixed separators on Windows; `[Console]::OutputEncoding` defaults differ across platforms. If a sibling function already handles the cross-platform case (e.g., sets UTF-8, resolves the executable via `Get-Command`), the new/modified function must do the same.
  - **Sibling function parity:** when the diff modifies one of a pair of related functions (e.g., `Invoke-Foo` and `Invoke-FooStream`, `Get-X` and `Set-X`), check whether the sibling already handles something the modified function does not: encoding, error handling, executable resolution, parameter validation. If the sibling does it, the modified function likely should too.
  - **Regex precision:** when the diff adds or modifies a regex, verify it does not over-match (matching legitimate content it should skip) or under-match (missing common variants of the target pattern). Example: an ANSI-stripping regex `\[[0-9;?]*[@-~]` also matches normal bracketed text like `[1]` because `]` falls in `[@-~]`. Example: a "Closes #123" regex that misses `Closes: #123` or `Closes owner/repo#123`.
  - **State mutation order:** when code clears/resets state (e.g., closing a modal, clearing a cache) and then reads a value that was part of that state, verify the read happens BEFORE the clear. Common bug: `closeModal()` nulls a variable, then the next line tries to use it for a toast message or log entry.
  - **Placeholder / broken references:** flag any `REPLACE_ME`, `TODO`, `FIXME`, `TBD`, or `XXX` tokens in non-comment code or user-facing strings. Also flag references to files or paths that do not exist in the repo (e.g., doc links to `docs/adr/` when the actual path is `workspace/decisions/`).

  **PowerShell (.ps1, .psm1):**
  - Array unwrapping: single-element `@()` results becoming a bare scalar. Wrap in `@(...)` when the consumer expects an array.
  - `$null` comparison order: `$val -eq $null` filters an array instead of returning a boolean. Correct form: `$null -eq $val`.
  - `-eq` / `-ne` on arrays returns filtered results, not a boolean. Guard with `-contains`, `-in`, or `.Count`.
  - `Write-Output` (or bare expression) inside a function pollutes the return value. Only the intended output should reach the pipeline.
  - `-ErrorAction SilentlyContinue` on operations where failure must be detected (file I/O, network calls, JSON parsing). Acceptable on enumeration/probing calls.
  - `ConvertTo-Json` without explicit `-Depth` defaults to depth 2, silently truncating nested objects. Require `-Depth N` on every call where the object may nest beyond 2 levels.
  - Regex injection: `-match` or `-replace` with user/variable input that is not wrapped in `[regex]::Escape()`.
  - `$LASTEXITCODE` not checked or not reset between native executable calls.
  - String concatenation building file paths instead of `Join-Path`.
  - Cross-platform path construction: `Join-Path $base "sub\path"` with hardcoded backslashes only works on Windows. Use nested `Join-Path` calls or `[System.IO.Path]::Combine()` for cross-platform paths.
  - `[Console]::OutputEncoding` / `[Console]::InputEncoding` not set to UTF-8 before piping to/from native executables. If a sibling function (e.g., the `-Stream` variant) already sets UTF-8, the modified function must too.
  - `catch { }` or `catch { continue }` on operations where failure should be surfaced to the caller (file writes, API calls, JSON parsing). Silently swallowing errors causes "success" responses when data was actually lost. Acceptable only for best-effort/probe operations where failure is expected and non-critical.

  **.NET / C# (.cs):**
  - Missing `await`, wrong `ConfigureAwait`, leaked `IDisposable`.
  - `async void` methods — exceptions are lost and the method is untestable. Must be `async Task` unless it is an event handler.
  - Polly retry placement on non-idempotent calls, EF Core tracking footguns.
  - LINQ deferred execution captured in a field/property that is enumerated multiple times (materialise with `.ToList()`).
  - String comparison without `StringComparison.Ordinal` or `OrdinalIgnoreCase` where culture-sensitivity is unintended.
  - Regex without `RegexOptions.Compiled` in hot paths, or unbounded patterns vulnerable to catastrophic backtracking.
  - Unobserved `Task` exceptions (fire-and-forget without `ContinueWith` or discard).
  - Concurrent modification of a non-thread-safe collection (`List<T>`, `Dictionary<K,V>`) from multiple threads.

  **JavaScript (.js) — Web UI frontend:**
  - Global variable pollution: assignments to `window.*` or undeclared variables that collide with other modules.
  - Event listeners added in a render/update function without removing prior listeners (causes duplicates on re-render).
  - `setTimeout`/`setInterval` without cleanup on teardown or navigation.
  - Type coercion bugs: `==` instead of `===`, falsy checks on values where `0` or `""` are valid.
  - `fetch()` calls without error handling (missing `.catch()` or `response.ok` check). Every `fetch()` in the diff must either check `response.ok` before parsing the body, or the surrounding code must handle non-2xx responses via the `.success` field on the parsed JSON. If neither guard exists, it's a bug.
  - `JSON.parse()` on untrusted input without try/catch.
  - **Sanitize-then-check ordering:** when code sanitizes a value (strips sequences, trims whitespace) and then conditionally renders it, verify the condition checks the sanitized value, not the raw value. Common bug: `if (value) { render(strip(value)) }` — the raw `value` is truthy but `strip(value)` is empty, producing blank UI elements.
- **Agent 4 — DOTBOT security.** Highest priority for this project. Check:
  - Secret leakage into `.claude-audit/` archives — redaction must run **before** write, not after.
  - Prompt injection surfaces in the steering/whisper channel and any agent input path.
  - Command injection in PowerShell shell-outs and `Start-Process` calls.
  - Path traversal in audit/session paths and MCP tool parameters (`plan-get`, `plan-update`, `task-mark-done` all accept paths or IDs that resolve to paths).
  - Unsafe deserialization (esp. session/state files).
  - Hardcoded keys, tokens, connection strings.

  **PowerShell-specific security:**
  - `-Path` vs `-LiteralPath` wildcard injection: `Test-Path $var`, `Get-Content -Path $var`, `Get-Item $var`, `Get-ChildItem -Path $var`, `Remove-Item -Path $var`, and `Resolve-Path $var` all expand wildcards (`*`, `?`, `[`) when using `-Path` (the default parameter). Any path derived from user/external input must use `-LiteralPath` to prevent wildcard expansion. The codebase already uses `-LiteralPath` correctly in `server.ps1` and decision tools — inconsistency elsewhere is a finding.
  - Double-quoted string interpolation leaking variables: `"Error for user $password"` or `"Path: $env:SECRET_KEY"` in log/output strings can leak secrets. Verify that double-quoted strings with `$` references do not accidentally interpolate sensitive variables.
  - Dynamic invocation without allowlist: `& $variable` or `. $variable` where the variable is derived from external input without validation against a fixed set of known-safe values. Note: `dotbot-mcp.ps1` validates tool names via `$tools.ContainsKey()` before constructing the function name — this pattern is the correct baseline.
  - Dot-sourcing from untrusted or variable paths: `. $scriptPath` where `$scriptPath` is not hardcoded or validated. Allows arbitrary code execution.
  - Module import from variable paths: `Import-Module $modulePath` where the path is not anchored to a known-safe directory.

  **JavaScript/Web UI security:**
  - DOM injection via `innerHTML`/`insertAdjacentHTML` with unsanitized data. The codebase has `escapeHtml()` in `utils.js` — any `innerHTML` assignment using template literals must pass dynamic values through `escapeHtml()`. Flag any `innerHTML` where interpolated variables bypass it.
  - Prototype pollution: `Object.assign(target, untrustedObj)` or spreading untrusted input into config objects.
  - Open redirect: any `window.location` or `window.open()` assignment using a value from URL params, API response, or user input without validation.
- **Agent 5 — Architecture & observability fit.** Vertical slice boundaries respected? DI used over `new`-ing services? Serilog structured logging with no secrets in messages? Log level appropriate? Does this duplicate an existing helper? PowerShell theme module (`DotBotTheme.psm1`) used for any new CLI output instead of raw `Write-Host` colors? For JS changes: does the new code follow the existing pattern (vanilla JS module in `static/modules/`, loaded by `app.js`)? Does it duplicate utility functions already in `utils.js`? Is `escapeHtml()` imported from the shared source rather than redefined locally?

  **Write-read contract verification:** When the diff writes data to a file path (state files, prompts, config), grep the codebase for any code that reads from that path. If no consumer exists, the write is orphaned. Also check whether the data already has an established canonical storage location — if the existing codebase writes/reads from a different path for the same purpose, the new code may be creating a divergent state source.

**Test coverage enforcement:**
Every PR that adds or modifies functionality **must** include corresponding tests. After the 5 agents complete, perform a test coverage check:

1. Identify all changed/added files in the diff that contain functional code (`.ps1`, `.psm1`, `.cs`, `.ts`, `.js`, etc. — exclude docs, configs, markdown).
2. For each functional file changed, check whether the diff also includes changes to a corresponding test file in the `tests/` folder (or equivalent test directory for the stack).
3. For new public functions, classes, or API endpoints — verify at least one test exercises the new code path.
4. For bug fixes — verify a regression test exists that would have caught the original bug.
5. For modified behavior — verify existing tests are updated to reflect the new behavior.
6. For JavaScript/frontend files — since the Web UI currently has no formal test harness, do not flag missing JS tests as MAJOR. Instead, flag code patterns that prevent future testability: module-scope side effects, direct DOM manipulation outside of a render function, or reliance on global state that cannot be injected.

**Test quality checks** (apply to test files IN the diff, not pre-existing tests):
- **False-positive tests:** if a test checks a condition only when a prerequisite file/directory exists and silently passes when it doesn't, the test gives false confidence. The test should either assert the prerequisite exists or explicitly skip with a message.
- **Incomplete mocks:** if a mock/stub function doesn't accept all the parameters that the real code passes (e.g., mock `Start-Process` that ignores `-NoNewWindow`), the test will break when those parameters are exercised.
- **Cleanup only on success path:** if temp files/directories are created in a test and `Remove-Item` runs only in the success path (not in `finally`), test failures will leak state. With `$ErrorActionPreference = 'Stop'`, any exception skips the cleanup.
- **Regex in assertions:** PowerShell `-match` treats `$` as a regex anchor, not a literal. Assertions that match PowerShell source code containing `$variable` must escape the dollar sign with a single backslash in the regex (`\$variable`) and use a single-quoted PowerShell string to avoid `$` interpolation, or the regex will silently fail to match.

If tests are missing, raise a `[MAJOR]` finding — missing test coverage is always MAJOR severity:
```
[MAJOR] src/Services/NewFeature.ps1 — missing test coverage (entire file)
New functionality added without corresponding tests. The tests/ folder has no
Test-NewFeature.ps1 or equivalent covering the added functions.

Expected: tests/Test-NewFeature.ps1 with tests for Get-FeatureData and Set-FeatureConfig.
```

Exceptions (do **not** flag missing tests for):
- Pure documentation changes (`.md` files only)
- Configuration file changes (`.json`, `.yaml`, `.toml`) that don't affect runtime logic
- Skill files (`SKILL.md`) — these are agent instruction files, not executable code
- CI/CD pipeline definitions (`.github/workflows/*.yml`, `.azure-pipelines.yml`)
- Environment and editor configs (`.gitignore`, `.editorconfig`, `.env.example`, `.vscode/`)
- CSS/SCSS/style-only changes with no logic
- Trivial renames or moves with no behavioral change
- Dependency version bumps with no code changes (e.g. updating a version number in `.csproj` or `package.json`)
- Generated files or build artifacts
- Comment-only changes (adding/editing code comments without functional change)
- Hook scripts that are integration-tested via existing hook test infrastructure

**Do not flag:**
- Style issues a linter would catch.
- Pre-existing issues on lines the diff didn't touch.
- Anything the agent can't validate from the diff + named convention files.
- Issues already flagged and unresolved by a prior automated reviewer (reference the existing comment instead).

### Step 3 — Validate every issue
For each issue from Steps 2, launch a parallel validator. Validator gets: PR title/description, the issue, the relevant `CLAUDE.md` paths. Its job is to confirm the issue is real and in-scope for the diff. For convention violations, it must verify the cited rule exists and applies to that file path.

### Step 4 — Confidence scoring
Score each surviving issue 0–100. Use this rubric verbatim in the scorer prompt:

- **0** — Not confident. False positive on light scrutiny, or pre-existing.
- **25** — Maybe real, maybe not. Couldn't verify. Stylistic and not in `CLAUDE.md` → score here.
- **50** — Plausible but needs reviewer judgment.
- **75** — Confident. Real issue, clear evidence in the diff.
- **100** — Certain. Reproducible from the diff alone, or quotes a `CLAUDE.md` rule verbatim that the diff plainly breaks.

Threshold: drop everything below **80**.

**Security bias:** Do not downgrade security findings (path traversal, injection, secret leak) below the agent's original score based on assumed mitigations (e.g., "the framework probably normalizes this"). If a mitigation is not **visible in the diff itself**, the security finding stands at the agent's score. Err on the side of reporting security issues — a false positive on security is far cheaper than a miss.

### Step 5 — Output (terminal display)

Group surviving findings by severity for the terminal report shown to the user. This detailed format is for the **terminal display only** — it does NOT go into the GitHub review body (see Step 6 for posting rules). Severity is assigned by the scorer based on impact, not score:

- `BLOCKER` — security, data loss, secret leak, broken build path.
- `MAJOR` — correctness bug, architecture violation, observability gap on a critical path.
- `MINOR` — localized bug, convention drift.
- `NIT` — only if explicitly called out in `CLAUDE.md`.

Each finding must include explicit line references and code examples:

```
[SEVERITY] path/to/file.cs:L42-L48
What's wrong (one sentence). Why it matters (one sentence).

Current code (lines 42-48):
    var session = taskContext.Session;
    var name = session.Name;  // potential NullReferenceException

Suggested fix:
    var session = taskContext.Session;
    var name = session?.Name ?? string.Empty;

Rule: <CLAUDE.md quote, if applicable>
```

Always include:
- The exact file path and line range from the diff
- A snippet of the current code at those lines (≤10 lines)
- A concrete suggested fix showing what the corrected code should look like
- Never rewrite large sections — show only the minimal change needed

**Prior Agent Review Summary** (include at the end, before the verdict):

```
## Prior Agent Review Summary

| Agent | File | Lines | Finding | dotbot-code-review Agrees? |
|-------|------|-------|---------|---------------------------|
| @coderabbitai[bot] | src/TaskRunner.cs | L42-L48 | Missing null check | Yes — confirmed, raised as MAJOR |
| @copilot[bot] | scripts/deploy.ps1 | L15 | Hardcoded path | No — path is compile-time constant |

Unresolved prior comments reviewed: 2
Confirmed: 1 | Disputed: 1 | Already resolved: 0
```

If no prior automated reviews existed: "No prior automated reviews found on this PR."

End with a one-line verdict:
- `ship` — no blockers or majors.
- `fix majors first` — no blockers, has majors.
- `needs rework` — has blockers.

If nothing survives the threshold: `No issues found. Checked DOTBOT conventions, bugs, security, and architecture fit.` Then the verdict line.

### Step 6 — Post review comments to GitHub PR

Post findings as line-level review comments on the PR using the GitHub API. **Each finding becomes its own inline comment** with its own "Resolve" button on GitHub — this is critical for the reviewer workflow.

**Architecture of the review payload:**

The GitHub "Create a review" API (`POST /repos/{owner}/{repo}/pulls/{number}/reviews`) takes:
- `body` — the **summary-only** review body (short: counts, prior-review table, verdict). **Never put full finding details in the body.** Findings go exclusively in `comments`.
- `event` — `APPROVE`, `REQUEST_CHANGES`, or `COMMENT`
- `comments` — array of inline comment objects, **one per finding**. Each becomes a separate conversation thread with its own Resolve button.

**Every surviving finding MUST be an inline comment.** No exceptions. Do not put finding descriptions, code snippets, or suggested fixes in the review `body`. The body is a dashboard; the comments are the actionable items.

**Build one comment object per finding:**

```json
{
  "path": "src/Services/TaskRunner.cs",
  "start_line": 42,
  "line": 48,
  "side": "RIGHT",
  "body": "[MAJOR] Missing null check on `session` before property access.\n\nThis will throw `NullReferenceException` when `taskContext.Session` is null.\n\n```suggestion\n    var session = taskContext.Session;\n    var name = session?.Name ?? string.Empty;\n```\n\n**Rule:** \"All nullable references must use null-conditional or guard clauses\" — CLAUDE.md"
}
```

**Line number rules for inline comments:**
- `line` (required) — the last line of the range in the diff (RIGHT side = new code)
- `start_line` (optional) — the first line of the range. Omit for single-line comments.
- Both `line` and `start_line` **must fall within the diff hunks** for that file. GitHub rejects comments on lines not in the diff.
- For findings that cannot be pinned to a specific diff line (e.g., "missing test coverage"), attach the comment to the **first changed line** of the most relevant file in the diff. The comment body should explain the broader scope.

**Comment body rules:**
- Start with `[SEVERITY]` tag
- Include the one-sentence problem and one-sentence impact
- Use a fenced `suggestion` block with the corrected code — GitHub renders this as a clickable "Apply suggestion" button
- Include the `CLAUDE.md` rule reference if applicable
- For multi-line suggestions, `start_line` is the first line and `line` is the last line of the range

**Critical: JSON escaping of suggestion blocks.** The suggestion fence must survive JSON serialization. In the comment body string, use literal `\n` for newlines and escaped backticks. The rendered body must contain exactly:
```
```suggestion
corrected code here
```
```
When building the body in PowerShell, use a here-string or explicit `\n` joins — do NOT let `ConvertTo-Json` mangle the triple-backtick fences. Verify the rendered comment in a test PR before trusting the escaping.

**Build the summary-only review body:**

The review body should contain ONLY:
1. One-line stats: files reviewed, findings count
2. Prior Agent Review Summary table (from Step 1b)
3. One-line verdict

Example:
```
## dotbot-code-review Summary

Reviewed 6 files, 2 findings survived confidence threshold (>=80).

### Prior Agent Review Summary

| Agent | File | Finding | Agrees? |
|-------|------|---------|---------|
| @copilot | server.ps1 | JSON parse swallowed | Yes — fixed |

Unresolved prior comments reviewed: 1 | Confirmed: 1

Verdict: **fix majors first**
```

**Submit the review:**

```pwsh
# Resolve owner/repo from the current git remote
$remote = git remote get-url origin
$ownerRepo = ($remote -replace '.*github\.com[:/]' -replace '\.git$')

# Get full SHA (short refs don't render in GitHub markdown)
$commitSha = git rev-parse HEAD

# Determine review event based on verdict
$event = switch ($verdict) {
    'ship'            { 'APPROVE' }
    'fix majors first' { 'REQUEST_CHANGES' }
    'needs rework'    { 'REQUEST_CHANGES' }
    default           { 'COMMENT' }
}

# Build review JSON — body is summary-only, ALL findings are inline comments
$reviewPayload = @{
    commit_id = $commitSha
    body      = $summaryBody    # SHORT: stats + prior-review table + verdict ONLY
    event     = $event
    comments  = @(
        # One entry per finding — each gets its own Resolve button:
        @{
            path       = "src/Services/TaskRunner.cs"
            start_line = 42
            line       = 48
            side       = "RIGHT"
            body       = "[MAJOR] ..."
        },
        @{
            path       = "tests/Test-TaskRunner.ps1"
            line       = 1    # first changed line — for "missing tests" findings
            side       = "RIGHT"
            body       = "[MAJOR] Missing test coverage for ..."
        }
    )
} | ConvertTo-Json -Depth 10

# Post the review via GitHub API
$reviewPayload | gh api "repos/$ownerRepo/pulls/{pr_number}/reviews" --input -
```

**Fallback:** If posting via API fails (e.g. permissions), fall back to `gh pr comment` with the full text report and warn the user that inline comments could not be posted.

**Link format:** When referencing code in the summary body, use permanent links:
```
https://github.com/{owner}/{repo}/blob/{FULL_SHA}/{path}#L{start}-L{end}
```
Full SHA required — short refs don't render in GitHub markdown.

## Hard rules

- Never invent issues to look thorough. A clean diff gets a clean report.
- Never flag what a linter would catch.
- Never quote more than 10 lines of source per finding.
- Never rewrite the author's code wholesale — show the minimal fix.
- Never bypass the 80 threshold "just to mention" something.
- Never duplicate an issue already flagged by another automated reviewer — reference the existing comment instead.
- Always include the exact file path and line range for every finding.
- Always include a concrete code suggestion showing the fix.
- Tone: punchy, no-frills, terminal-report. No emoji. No praise sandwich.
