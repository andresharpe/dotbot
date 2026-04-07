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

# Get review threads with resolution status
gh pr view {pr_number} --json reviewThreads,reviews
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
- `isResolved` — whether the thread has been resolved (from `reviewThreads`)

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
- **Agent 3 — Bug hunter.** Diff-only. Logic errors, off-by-ones, null/empty handling, broken contracts, race conditions, missing `await`, wrong `ConfigureAwait`, leaked `IDisposable`, Polly retry placement on non-idempotent calls, EF Core tracking footguns. Flag only what is verifiable inside the diff. No nitpicks.
- **Agent 4 — DOTBOT security.** Highest priority for this project. Check:
  - Secret leakage into `.claude-audit/` archives — redaction must run **before** write, not after.
  - Prompt injection surfaces in the steering/whisper channel and any agent input path.
  - Command injection in PowerShell shell-outs and `Start-Process` calls.
  - Path traversal in audit/session paths.
  - Unsafe deserialization (esp. session/state files).
  - Hardcoded keys, tokens, connection strings.
- **Agent 5 — Architecture & observability fit.** Vertical slice boundaries respected? DI used over `new`-ing services? Serilog structured logging with no secrets in messages? Log level appropriate? Does this duplicate an existing helper? PowerShell theme module (`DotBotTheme.psm1`) used for any new CLI output instead of raw `Write-Host` colors?

**Test coverage enforcement:**
Every PR that adds or modifies functionality **must** include corresponding tests. After the 5 agents complete, perform a test coverage check:

1. Identify all changed/added files in the diff that contain functional code (`.ps1`, `.psm1`, `.cs`, `.ts`, `.js`, etc. — exclude docs, configs, markdown).
2. For each functional file changed, check whether the diff also includes changes to a corresponding test file in the `tests/` folder (or equivalent test directory for the stack).
3. For new public functions, classes, or API endpoints — verify at least one test exercises the new code path.
4. For bug fixes — verify a regression test exists that would have caught the original bug.
5. For modified behavior — verify existing tests are updated to reflect the new behavior.

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

### Step 5 — Output

Group surviving findings by severity. Severity is assigned by the scorer based on impact, not score:

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

Post findings as line-level review comments on the PR using the GitHub API. This ensures each finding appears inline on the exact code it references.

**Build the review payload:**

For each surviving finding, construct a review comment object:

```json
{
  "path": "src/Services/TaskRunner.cs",
  "start_line": 42,
  "line": 48,
  "side": "RIGHT",
  "body": "[MAJOR] Missing null check on `session` before property access.\n\nThis will throw `NullReferenceException` when `taskContext.Session` is null.\n\n```suggestion\n    var session = taskContext.Session;\n    var name = session?.Name ?? string.Empty;\n```\n\n**Rule:** \"All nullable references must use null-conditional or guard clauses\" — CLAUDE.md"
}
```

Key rules for the comment body:
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

**Submit the review:**

```pwsh
# Resolve owner/repo from the current git remote
$remote = git remote get-url origin
$ownerRepo = ($remote -replace '.*github\.com[:/]' -replace '\.git$')

# Get full SHA (short refs don't render in GitHub markdown)
$commitSha = git rev-parse HEAD

# Build the review body (summary + verdict)
$reviewBody = @"
## dotbot-code-review Summary

Reviewed {N} files, {M} findings survived confidence threshold (≥80).

Verdict: **{verdict}**
"@

# Determine review event based on verdict
$event = switch ($verdict) {
    'ship'            { 'APPROVE' }
    'fix majors first' { 'REQUEST_CHANGES' }
    'needs rework'    { 'REQUEST_CHANGES' }
    default           { 'COMMENT' }
}

# Build review JSON with inline comments
$reviewPayload = @{
    commit_id = $commitSha
    body      = $reviewBody
    event     = $event
    comments  = @(
        # One entry per finding:
        @{
            path       = "src/Services/TaskRunner.cs"
            start_line = 42
            line       = 48
            side       = "RIGHT"
            body       = "[MAJOR] ..."
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
