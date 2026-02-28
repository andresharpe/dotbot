# Validation Task 10: Test Suite Coverage & CI Readiness

## Scope
Validate that all test layers pass, new tests are comprehensive, and CI will not break on this PR.

## Files to Review
- `tests/Test-Structure.ps1` (Layer 1 — new provider config tests)
- `tests/Test-Components.ps1` (Layer 2 — new ProviderCLI module tests)
- `tests/Test-MockClaude.ps1` (Layer 3 — backward compat)
- `tests/Run-Tests.ps1` (test runner)
- `tests/mock-codex.ps1`, `tests/mock-gemini.ps1`
- `tests/codex`, `tests/codex.cmd`, `tests/gemini`, `tests/gemini.cmd`

## Checks

### Layer 1 Structure Tests (22 new)
- [ ] All 3 provider JSON files: exist, parse, have `name`, `models`, `executable`, `stream_parser`
- [ ] `settings.default.json` has `provider` field
- [ ] `ProviderCLI.psm1` exists
- [ ] All 3 stream parsers exist: `Parse-ClaudeStream.ps1`, `Parse-CodexStream.ps1`, `Parse-GeminiStream.ps1`
- [ ] Tests are in the "PROVIDER CONFIGS" section before SUMMARY

### Layer 2 Component Tests (7 new)
- [ ] ProviderCLI module loads successfully
- [ ] `Get-ProviderConfig` loads claude config
- [ ] `Get-ProviderModels` returns 2+ models
- [ ] `Resolve-ProviderModelId` maps "Opus" to `claude-opus-4-6`
- [ ] `Resolve-ProviderModelId` throws for "Opus" on codex
- [ ] `New-ProviderSession` returns GUID for Claude
- [ ] `New-ProviderSession` returns null for Codex
- [ ] Tests use `$dotbotDir` (installed location), not `$repoRoot`

### Layer 3 Mock Tests (0 new, backward compat)
- [ ] All 8 existing tests still pass
- [ ] Mock claude CLI still works through the ProviderCLI delegation layer
- [ ] Rate limit detection still works

### Cross-Platform
- [ ] No Windows-specific path separators in tests
- [ ] Mock CLIs have both Unix shims and `.cmd` Windows shims
- [ ] `#!/usr/bin/env pwsh` shebang on all mock scripts

### CI Pipeline
- [ ] No new test files that need to be registered in `Run-Tests.ps1`
- [ ] No new dependencies required (no new modules to install)
- [ ] Tests don't require ANTHROPIC_API_KEY (layers 1-3 only)
- [ ] Tests don't require OPENAI_API_KEY or GEMINI_API_KEY
- [ ] `install.ps1` correctly copies new files to install dir

### Diff Review
- [ ] Total: 12 new files, 13 modified files
- [ ] No accidental deletions of existing functionality
- [ ] No debug code left in (console.log, Write-Host for debugging, etc.)
- [ ] No secrets or API keys in any files
- [ ] No TODO/FIXME/HACK comments that should be resolved before merge

## How to Test
```bash
# Full test suite
pwsh tests/Run-Tests.ps1

# Expected output:
# Layer 1: ~79 passed, 0 failed
# Layer 2: ~39 passed, 0 failed
# Layer 3: ~8 passed, 0 failed
# RESULT: ALL PASSED

# Verify install copies everything
pwsh install.ps1
ls ~/dotbot/profiles/default/defaults/providers/
ls ~/dotbot/profiles/default/systems/runtime/ProviderCLI/
ls ~/dotbot/profiles/default/systems/runtime/ProviderCLI/parsers/

# Verify diff is clean
git diff --stat
git status -u
```
