# Validation Task 4: launch-process.ps1 Rewire Audit

## Scope
Audit every change in `launch-process.ps1` to ensure the provider abstraction is wired correctly without regressions.

## Files to Review
- `profiles/default/systems/runtime/launch-process.ps1`
- `profiles/default/systems/runtime/expand-task-groups.ps1`

## Checks

### Parameter Changes
- [ ] `[ValidateSet('Opus', 'Sonnet', 'Haiku')]` removed from `$Model` parameter — model aliases are now provider-dependent
- [ ] All other parameters unchanged

### Configuration Section
- [ ] `$modelMap` hashtable removed (was hardcoded Claude model IDs)
- [ ] `$providerConfig = Get-ProviderConfig` loads active provider
- [ ] Model resolution uses `$providerConfig.default_model` as fallback
- [ ] `Resolve-ProviderModelId` replaces `$modelMap[$Model]` lookup
- [ ] `$env:DOTBOT_MODEL` set alongside `$env:CLAUDE_MODEL` for backward compat

### Module Imports
- [ ] `Import-Module ProviderCLI.psm1` added alongside ClaudeCLI import
- [ ] ClaudeCLI import kept (needed for backward compat and helpers like `Write-ActivityLog`)

### Invoke-ClaudeStream -> Invoke-ProviderStream (8 sites)
- [ ] Line ~745: workflow analysis invocation
- [ ] Line ~1184: analysis loop invocation
- [ ] Line ~1383: execution loop invocation
- [ ] Line ~1680: interview invocation
- [ ] Line ~1862: kickstart invocation
- [ ] Line ~1934: planning Phase 2a invocation
- [ ] Line ~2238: commit invocation
- [ ] Line ~2325: task-creation invocation
- [ ] All `@streamArgs` splatting unchanged (same parameter names)

### Get-LastRateLimitInfo -> Get-LastProviderRateLimitInfo (3 sites)
- [ ] All three rate limit check sites updated
- [ ] Rate limit handler logic unchanged around these calls

### Session ID Creation (5 sites)
- [ ] Initial: `New-ProviderSession` replaces `[Guid]::NewGuid().ToString()`
- [ ] Per-task analysis session: `New-ProviderSession`
- [ ] Per-task execution session: `New-ProviderSession`
- [ ] Interview session: `New-ProviderSession`
- [ ] Phase 2a session: `New-ProviderSession`
- [ ] `$env:CLAUDE_SESSION_ID` still set for backward compat

### Session Cleanup (3 sites)
- [ ] All `Remove-ClaudeSession` calls replaced with `Remove-ProviderSession`

### Preflight
- [ ] `Test-Preflight` checks `$providerConfig.executable` instead of hardcoded `claude`
- [ ] Error message includes provider display name

### expand-task-groups.ps1
- [ ] `Import-Module ProviderCLI` added
- [ ] Single `Invoke-ClaudeStream` call replaced with `Invoke-ProviderStream`

## How to Test
```bash
# Verify no remaining hardcoded references
grep -n "Invoke-ClaudeStream" profiles/default/systems/runtime/launch-process.ps1
grep -n "Get-LastRateLimitInfo[^P]" profiles/default/systems/runtime/launch-process.ps1
grep -n "Remove-ClaudeSession" profiles/default/systems/runtime/launch-process.ps1
grep -n "modelMap" profiles/default/systems/runtime/launch-process.ps1
grep -n "NewGuid" profiles/default/systems/runtime/launch-process.ps1

# Run Layer 3 mock tests (backward compat)
pwsh tests/Run-Tests.ps1 -Layer 3
```
