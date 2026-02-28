# Validation Task 7: Init Triple Provider Setup

## Scope
Validate that `dotbot init` creates all three IDE directories with correct agents, skills, and MCP registration.

## Files to Review
- `profiles/default/init.ps1`
- `scripts/init-project.ps1`

## Checks

### init.ps1 — Triple IDE Directory Setup
- [ ] Creates `.claude/`, `.codex/`, `.gemini/` directories
- [ ] Copies agents to all three: `.claude/agents/`, `.codex/agents/`, `.gemini/agents/`
- [ ] Copies skills to all three: `.claude/skills/`, `.codex/skills/`, `.gemini/skills/`
- [ ] Agent count reported per directory in output
- [ ] Skill count reported per directory in output

### init.ps1 — Model Rewriting
- [ ] `.claude/agents/*/AGENT.md` keep `model: claude-opus-4-6` (unchanged from source)
- [ ] `.codex/agents/*/AGENT.md` have `model: gpt-5.2-codex` (rewritten)
- [ ] `.gemini/agents/*/AGENT.md` have `model: gemini-2.5-pro` (rewritten)
- [ ] All four agents rewritten: implementer, planner, reviewer, tester
- [ ] Only the `model:` line is changed, rest of AGENT.md preserved
- [ ] Regex handles various claude model ID formats (claude-opus-4-6, claude-sonnet-*, etc.)

### init.ps1 — Provider Config Loading
- [ ] Reads from `defaults/providers/*.json` to get model IDs
- [ ] Handles missing provider config gracefully (skip rewrite)
- [ ] Handles malformed provider config gracefully

### init-project.ps1 — CLI Detection
- [ ] Reports Claude CLI status (installed or warning)
- [ ] Reports Codex CLI status (installed or warning)
- [ ] Reports Gemini CLI status (installed or warning)
- [ ] Install instructions shown for missing CLIs
- [ ] Missing CLIs are warnings, not fatal errors

### init-project.ps1 — MCP Registration
- [ ] `.mcp.json` created for Claude (existing behavior, unchanged)
- [ ] `codex mcp add dotbot ...` called if codex CLI available
- [ ] `gemini mcp add dotbot ...` called if gemini CLI available
- [ ] MCP registration failures are warnings, not fatal
- [ ] Correct MCP server command: `pwsh -NoProfile -ExecutionPolicy Bypass -File .bot\systems\mcp\dotbot-mcp.ps1`

### init-project.ps1 — Gitignore
- [ ] `.codex/` added to required gitignore patterns
- [ ] `.gemini/` added to required gitignore patterns
- [ ] `.serena/` and other existing patterns preserved

## How to Test
```bash
# Create a fresh test project
mkdir /tmp/test-provider-init && cd /tmp/test-provider-init
git init
dotbot init

# Verify directory structure
ls -la .claude/agents/ .codex/agents/ .gemini/agents/

# Check model fields
grep "model:" .claude/agents/implementer/AGENT.md
grep "model:" .codex/agents/implementer/AGENT.md
grep "model:" .gemini/agents/implementer/AGENT.md

# Check gitignore
grep "codex\|gemini" .gitignore

# Cleanup
rm -rf /tmp/test-provider-init
```
