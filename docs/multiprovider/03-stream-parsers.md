# Validation Task 3: Stream Parser Correctness

## Scope
Validate that all three stream parsers handle their respective event formats correctly and degrade gracefully on malformed input.

## Files to Review
- `profiles/default/systems/runtime/ProviderCLI/parsers/Parse-ClaudeStream.ps1`
- `profiles/default/systems/runtime/ProviderCLI/parsers/Parse-CodexStream.ps1`
- `profiles/default/systems/runtime/ProviderCLI/parsers/Parse-GeminiStream.ps1`

## Checks

### Claude Parser
- [ ] Handles init event (`type=system, subtype=init, model, cwd`)
- [ ] Accumulates assistant text from `message.delta.text`
- [ ] Accumulates text from `message.content[].text`
- [ ] Tracks token usage from `message.usage`
- [ ] Handles tool_use events (type=assistant, content[].type=tool_use)
- [ ] Handles tool_result events (type=user, content[].type=tool_result)
- [ ] Handles result event (type=result, subtype=success/error)
- [ ] Detects rate limit in JSON responses
- [ ] Detects rate limit in plain text responses
- [ ] Returns 'skip' for non-JSON lines
- [ ] Returns correct disposition strings ('text', 'init', 'tool_use', etc.)

### Codex Parser
- [ ] Handles `thread.started` event (logs thread ID)
- [ ] Handles `turn.started` event
- [ ] Handles `message.delta` event (accumulates text)
- [ ] Handles `message.completed` event (flushes text, tracks usage)
- [ ] Handles `function_call` event (logs tool name)
- [ ] Handles `function_call_output` event
- [ ] Handles `turn.completed` event (shows summary)
- [ ] Handles `turn.failed` event (shows error)
- [ ] Handles `error` event including rate limit detection
- [ ] Skips non-JSON lines (stderr noise like `rmcp` errors)

### Gemini Parser
- [ ] Handles Claude-like init event (since Gemini uses similar format)
- [ ] Accumulates text from `message.delta.text` and `message.content`
- [ ] Handles tool_use and tool_result events
- [ ] Handles result event
- [ ] Detects rate limit in plain text (quota errors)
- [ ] Detects rate limit in JSON error events

### Edge Cases (all parsers)
- [ ] Empty lines are skipped
- [ ] Malformed JSON is skipped without crashing
- [ ] Lines starting with non-`{` characters are skipped
- [ ] `$State` hashtable is properly updated (assistantText, token counts)

## How to Test
```powershell
# Test Claude parser with mock events
$state = @{
    assistantText = [System.Text.StringBuilder]::new()
    totalInputTokens = 0; totalOutputTokens = 0
    totalCacheRead = 0; totalCacheCreate = 0
    pendingToolCalls = @(); lastUnknown = Get-Date
    theme = (Import-Module profiles/default/systems/runtime/modules/DotBotTheme.psm1 -Force -PassThru | % { Get-DotBotTheme })
}
. profiles/default/systems/runtime/ProviderCLI/parsers/Parse-ClaudeStream.ps1
Process-StreamLine -Line '{"type":"system","subtype":"init","model":"test","cwd":"/tmp"}' -State $state

# Run mock CLIs and check output
pwsh tests/mock-codex.ps1
pwsh tests/mock-gemini.ps1
```
