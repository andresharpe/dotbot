# Validation Task 5: Session & Cleanup Provider Awareness

## Scope
Validate that session management and cleanup functions correctly dispatch by provider, maintaining backward compatibility.

## Files to Review
- `profiles/default/systems/runtime/modules/cleanup.ps1`

## Checks

### Remove-ProviderSession
- [ ] For Claude: removes session folder at `~/.claude/projects/{hash}/{sessionId}/`
- [ ] For Claude: removes session file at `~/.claude/projects/{hash}/{sessionId}.jsonl`
- [ ] For Codex: returns `$false` (no-op)
- [ ] For Gemini: returns `$false` (no-op)
- [ ] Returns `$false` when `$SessionId` is empty/null
- [ ] Loads provider config via `Get-ProviderConfig` to determine active provider
- [ ] Handles `Get-ProviderConfig` failure gracefully (falls back to claude)

### Remove-ClaudeSession (backward compat)
- [ ] Function still exists as wrapper
- [ ] Delegates to `Remove-ProviderSession` with same parameters
- [ ] Existing call sites in launch-process.ps1 could use either name

### Clear-OldProviderSessions
- [ ] For Claude: cleans old `.jsonl` files (older than MaxAgeDays)
- [ ] For Claude: cleans old GUID session folders
- [ ] For Codex/Gemini: returns `0` (no-op)
- [ ] Preserves `sessions-index.json` (not deleted)

### Clear-OldClaudeSessions (backward compat)
- [ ] Function still exists as wrapper
- [ ] Delegates to `Clear-OldProviderSessions`

### Get-ClaudeProjectDir (internal helper)
- [ ] Still exists and works for Claude path resolution
- [ ] Correctly hashes project path: `C:\Users\foo` -> `C--Users-foo`
- [ ] Returns `$null` when directory doesn't exist

### Clear-TemporaryClaudeDirectories
- [ ] Unchanged — still removes `tmpclaude-*-cwd` dirs
- [ ] This is Claude-specific temp dir cleanup (not provider-dependent)

## How to Test
```powershell
# Import the module
. profiles/default/systems/runtime/modules/cleanup.ps1
Import-Module profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1 -Force

# Test Remove-ProviderSession
Remove-ProviderSession -SessionId "" -ProjectRoot "C:\temp"  # Should return $false
Remove-ProviderSession -SessionId "test-id" -ProjectRoot "C:\nonexistent"  # Should return $false

# Test backward compat
Remove-ClaudeSession -SessionId "test" -ProjectRoot "C:\temp"  # Should work
Clear-OldClaudeSessions -ProjectRoot "C:\temp"  # Should work
```
