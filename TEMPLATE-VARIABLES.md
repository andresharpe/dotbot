# Template Variables in dotbot

dotbot commands and workflows can use template variables to create dynamic, configuration-aware content.

## Overview

Template variables allow commands to adapt based on:
- Configuration settings (from config.yml)
- User preferences
- Project structure
- Conditional logic

## Variable Syntax

Variables are referenced using double curly braces:

```markdown
{{variable_name}}
```

## Configuration Variables

These variables come from `config.yml`:

### `warp_commands`
Whether Warp commands are enabled (installed to `.warp/commands/`).

**Usage:**
```markdown
{{IF warp_commands}}
This content appears when Warp integration is enabled.
{{ENDIF warp_commands}}
```

### `standards_as_warp_rules`
Whether standards are provided as Warp project rules in WARP.md.

**Usage:**
```markdown
{{IF standards_as_warp_rules}}
Add standards to WARP.md
{{ENDIF standards_as_warp_rules}}
```

### `dotbot_commands`
Whether dotbot commands are enabled.

### `profile`
The active profile name.

## Conditional Blocks

### IF Block
Shows content when condition is true:

```markdown
{{IF variable_name}}
Content shown when variable is true
{{ENDIF variable_name}}
```

### UNLESS Block
Shows content when condition is false:

```markdown
{{UNLESS variable_name}}
Content shown when variable is false
{{ENDUNLESS variable_name}}
```

## File References

Reference other files using the `@` syntax:

```markdown
{{workflows/implementation/implement-tasks}}
```

This tells the agent to follow that workflow file.

## Practical Examples

### Example 1: Conditional Warp Commands

```markdown
{{IF warp_commands}}
### Install to Warp

Copy commands to `.warp/commands/dotbot/` for slash command support.

Commands will be available as:
- `/plan-product`
- `/write-spec`
- `/implement-tasks`
{{ENDIF warp_commands}}
```

### Example 2: Conditional Standards Handling

```markdown
{{IF standards_as_warp_rules}}
## Add Standards to WARP.md

Include key standards as project rules in WARP.md for automatic agent guidance.
{{ENDIF standards_as_warp_rules}}

{{UNLESS standards_as_warp_rules}}
## Reference Standards Files

Reference standards as separate files:
- @.bot/standards/global/coding-style.md
- @.bot/standards/global/error-handling.md
{{ENDUNLESS standards_as_warp_rules}}
```

### Example 3: Workflow References

```markdown
## Perform the Implementation

Follow this workflow:
{{workflows/implementation/implement-tasks}}
```

## How Agents Interpret Variables

When an AI agent encounters template variables:

1. **Configuration Variables**: Agent checks config.yml for current values
2. **Conditional Blocks**: Agent includes or excludes content based on conditions
3. **File References**: Agent reads and follows the referenced file's instructions
4. **Variable Substitution**: Agent replaces `{{variable}}` with actual values

## Creating Commands with Variables

When creating command files:

```markdown
# My Command

{{IF use_claude_code_subagents}}
Step 1: Delegate to subagent

Instructions for delegation...
{{ENDIF use_claude_code_subagents}}

{{UNLESS use_claude_code_subagents}}
Step 1: Execute directly

Instructions for direct execution...
{{ENDUNLESS use_claude_code_subagents}}

Common step 2 that always runs...
```

## Best Practices

### Use Variables to Adapt Behavior
- Adapt commands based on tool availability
- Provide different paths for different setups
- Make commands configuration-aware

### Keep Logic Simple
- Avoid deeply nested conditionals
- Use clear variable names
- Document what each condition does

### Provide Fallbacks
- Always provide a path for both true and false cases
- Make sure commands work with default config
- Document required configuration

### Reference Files
- Use workflow references to avoid duplication
- Keep common logic in workflows
- Reference standards rather than copying them

## Variable Resolution Order

1. Check config.yml for explicit values
2. Use default values if not configured
3. Validate dependencies (e.g., subagents require Claude Code)
4. Apply conditional logic
5. Substitute final values

## Testing with Variables

When testing commands with variables:

1. **Test with defaults**: Use default config.yml
2. **Test with variations**: Try different config combinations
3. **Test both paths**: Verify both IF and UNLESS blocks
4. **Verify references**: Ensure file references work

## Example: orchestrate-tasks Command

The `orchestrate-tasks` command uses variables extensively:

- Uses `standards_as_warp_rules` to determine how to apply standards
- References workflows like `{{workflows/implementation/compile-standards}}`
- Generates structured prompts for Warp Agent Mode
- Adapts behavior based on configuration

## Future Variables

Potential future variables:
- `project_language` - Programming language of project
- `test_framework` - Testing framework in use
- `deployment_target` - Where code is deployed
- `team_size` - Solo vs team development

## Summary

Template variables make dotbot commands flexible and configuration-aware. They allow:
- ✅ Adaptive behavior based on setup
- ✅ Conditional content inclusion
- ✅ File and workflow references
- ✅ Configuration-driven workflows

Use them to create powerful, reusable commands that work across different project setups.

