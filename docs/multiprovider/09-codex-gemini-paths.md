# Validation Task 9: Codex & Gemini Execution Paths

## Scope
Validate that the non-Claude provider paths (Codex, Gemini) are correctly wired end-to-end, even though live testing requires API keys.

## Files to Review
- `profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1` (non-Claude path)
- `profiles/default/systems/runtime/ProviderCLI/parsers/Parse-CodexStream.ps1`
- `profiles/default/systems/runtime/ProviderCLI/parsers/Parse-GeminiStream.ps1`
- `tests/mock-codex.ps1`, `tests/mock-gemini.ps1`

## Checks

### Codex Execution Path
- [ ] `Build-ProviderCliArgs` for Codex produces: `exec -m <model> --dangerously-bypass-approvals-and-sandbox --json -- <prompt>`
- [ ] `exec` subcommand is first argument
- [ ] No `--session-id` in args (capabilities.session_id = false)
- [ ] No `--no-session-persistence` in args
- [ ] No `--print` or `--verbose` (cli_args are null)
- [ ] `New-ProviderSession` returns `$null`
- [ ] `Remove-ProviderSession` is a no-op
- [ ] Mock codex emits valid JSONL: `thread.started`, `turn.started`, `message.completed`, `turn.completed`
- [ ] Codex parser handles all mock events without errors

### Gemini Execution Path
- [ ] `Build-ProviderCliArgs` for Gemini produces: `-m <model> -y --output-format stream-json -p <prompt>`
- [ ] `-p` prompt flag used (not `-- <prompt>`)
- [ ] No `--session-id` in args
- [ ] No `--print` or `--verbose`
- [ ] `New-ProviderSession` returns `$null`
- [ ] `Remove-ProviderSession` is a no-op
- [ ] Mock gemini emits valid stream-json events (Claude-like format)
- [ ] Gemini parser handles all mock events without errors

### Provider Switching
- [ ] Changing `settings.default.json` `provider` to `codex` makes `Get-ProviderConfig` return codex
- [ ] `Resolve-ProviderModelId` uses codex model list when provider is codex
- [ ] `Resolve-ProviderModelId` rejects Claude model aliases for codex
- [ ] Model validation prevents using "Opus" when provider is "codex"

### Mock CLI Testing
- [ ] `tests/mock-codex.ps1` runs without errors
- [ ] `tests/mock-codex.ps1` logs prompt to file
- [ ] `tests/mock-codex.ps1` supports rate-limit mode
- [ ] `tests/mock-codex.ps1` supports error mode
- [ ] `tests/mock-gemini.ps1` runs without errors
- [ ] `tests/mock-gemini.ps1` logs prompt to file
- [ ] `tests/mock-gemini.ps1` supports rate-limit mode
- [ ] `tests/mock-gemini.ps1` supports error mode
- [ ] Unix shims (`tests/codex`, `tests/gemini`) work
- [ ] Windows shims (`tests/codex.cmd`, `tests/gemini.cmd`) work

## How to Test
```powershell
# Test arg building
Import-Module profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1 -Force

$codexConfig = Get-ProviderConfig -Name "codex"
$codexArgs = Build-ProviderCliArgs -Config $codexConfig -Prompt "hello" -ModelId "gpt-5.2-codex"
Write-Host "Codex args: $($codexArgs -join ' ')"

$geminiConfig = Get-ProviderConfig -Name "gemini"
$geminiArgs = Build-ProviderCliArgs -Config $geminiConfig -Prompt "hello" -ModelId "gemini-2.5-pro"
Write-Host "Gemini args: $($geminiArgs -join ' ')"

# Test mock CLIs
pwsh tests/mock-codex.ps1 exec -m gpt-5.2-codex --json -- "test prompt"
pwsh tests/mock-gemini.ps1 -m gemini-2.5-pro -y --output-format stream-json -p "test prompt"

# Test model rejection
try { Resolve-ProviderModelId -ModelAlias "Opus" -ProviderName "codex" } catch { Write-Host "Correctly rejected: $_" }
```
