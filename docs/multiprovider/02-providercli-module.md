# Validation Task 2: ProviderCLI Module Correctness

## Scope
Validate that `ProviderCLI.psm1` loads correctly, all exported functions work, and the Claude delegation path is transparent.

## Files to Review
- `profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1`

## Checks

### Module Loading
- [ ] Module imports without errors: `Import-Module ProviderCLI.psm1 -Force`
- [ ] All 8 functions are exported: `Get-ProviderConfig`, `Get-ProviderModels`, `Resolve-ProviderModelId`, `Build-ProviderCliArgs`, `Invoke-ProviderStream`, `Invoke-Provider`, `New-ProviderSession`, `Get-LastProviderRateLimitInfo`
- [ ] Module correctly imports DotBotTheme and ClaudeCLI as dependencies

### Get-ProviderConfig
- [ ] Returns claude config when no name specified (default from settings)
- [ ] Returns correct config when name is explicitly passed (claude, codex, gemini)
- [ ] Throws meaningful error for unknown provider name
- [ ] Reads user override from `.control/settings.json` when present

### Get-ProviderModels
- [ ] Returns correct model count for each provider (Claude: 3, Codex: 3, Gemini: 2)
- [ ] Each model has Alias, Id, Description, IsDefault fields
- [ ] Exactly one model per provider has `IsDefault = $true`

### Resolve-ProviderModelId
- [ ] Maps aliases correctly: "Opus" -> "claude-opus-4-6"
- [ ] Passes through full model IDs unchanged
- [ ] Throws on invalid alias for provider (e.g. "Opus" for codex)

### Build-ProviderCliArgs
- [ ] Claude args include: `--model`, `--dangerously-skip-permissions`, `--output-format stream-json`, `--print`, `--verbose`, `-- <prompt>`
- [ ] Codex args include: `exec`, `-m`, `--dangerously-bypass-approvals-and-sandbox`, `--json`, `-- <prompt>`
- [ ] Gemini args include: `-m`, `-y`, `--output-format stream-json`, `-p <prompt>`
- [ ] Session ID prepended for Claude, omitted for Codex/Gemini
- [ ] `--no-session-persistence` added for Claude when `PersistSession=$false`

### New-ProviderSession
- [ ] Returns GUID string for Claude
- [ ] Returns `$null` for Codex and Gemini

### Invoke-ProviderStream (Claude path)
- [ ] Delegates to `Invoke-ClaudeStream` for Claude provider
- [ ] Propagates rate limit info from `Get-LastRateLimitInfo`

## How to Test
```powershell
Import-Module profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1 -Force

# Test each function
Get-ProviderConfig -Name "claude"
Get-ProviderModels -ProviderName "codex"
Resolve-ProviderModelId -ModelAlias "Opus" -ProviderName "claude"
Build-ProviderCliArgs -Config (Get-ProviderConfig -Name "claude") -Prompt "test" -ModelId "claude-opus-4-6"
Build-ProviderCliArgs -Config (Get-ProviderConfig -Name "codex") -Prompt "test" -ModelId "gpt-5.2-codex"
New-ProviderSession -ProviderName "claude"
New-ProviderSession -ProviderName "codex"
```
