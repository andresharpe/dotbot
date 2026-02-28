# Validation Task 8: Claude Backward Compatibility

## Scope
Validate that all existing Claude workflows continue to work identically when `provider=claude` (the default). Nothing should break for users who never change their provider.

## Files to Review
- All modified files, with focus on the Claude execution path

## Checks

### Default Provider Path
- [ ] When `provider` field is missing from settings, defaults to `claude`
- [ ] When `provider` is `claude`, `Invoke-ProviderStream` delegates to `Invoke-ClaudeStream`
- [ ] `Invoke-ClaudeStream` itself is unchanged (except `--plugin-dir` removal)
- [ ] `--plugin-dir` removal is intentional (was a workaround for a resolved issue)

### Model Resolution
- [ ] `"Opus"` still resolves to `claude-opus-4-6`
- [ ] `"Sonnet"` still resolves to `claude-sonnet-4-5-20250929`
- [ ] `"Haiku"` still resolves to `claude-haiku-4-5-20251001`
- [ ] Settings `analysis.model: "Opus"` still works
- [ ] Settings `execution.model: "Opus"` still works
- [ ] `$env:CLAUDE_MODEL` still set for scripts that depend on it

### Session Management
- [ ] Session IDs still generated as GUIDs for Claude
- [ ] `$env:CLAUDE_SESSION_ID` still set
- [ ] Session cleanup still removes files from `~/.claude/projects/`

### ClaudeCLI.psm1 Preserved
- [ ] Module still exists and loads
- [ ] All original exports still work: `Invoke-ClaudeStream`, `Invoke-Claude`, `Get-ClaudeModels`, `New-ClaudeSession`, `Get-LastRateLimitInfo`, `Write-ActivityLog`
- [ ] Aliases still work: `ics`, `ic`, `gclm`, `ncs`

### Layer 3 Tests
- [ ] All existing mock-claude tests pass without modification
- [ ] Mock claude binary is still resolved correctly
- [ ] Rate limit detection still works through the provider layer

### Process Registry
- [ ] Process files still have `claude_session_id` field
- [ ] Heartbeat updates unchanged
- [ ] Process activity logging unchanged

## How to Test
```bash
# Run all three test layers
pwsh tests/Run-Tests.ps1

# Verify ClaudeCLI still works directly
pwsh -c "Import-Module profiles/default/systems/runtime/ClaudeCLI/ClaudeCLI.psm1 -Force; Get-ClaudeModels"

# Verify provider delegates to Claude
pwsh -c "
    Import-Module profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1 -Force
    `$config = Get-ProviderConfig
    Write-Host 'Active provider:' `$config.name
    Write-Host 'Should be: claude'
"

# Check env vars are set
grep "CLAUDE_MODEL\|DOTBOT_MODEL\|CLAUDE_SESSION_ID" profiles/default/systems/runtime/launch-process.ps1
```
