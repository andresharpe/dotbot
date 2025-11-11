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

### `use_claude_code_subagents`
Whether Claude Code subagents are enabled.

**Usage:**
```markdown
{{IF use_claude_code_subagents}}
This content appears only if subagents are enabled.
{{ENDIF use_claude_code_subagents}}
```

### `standards_as_claude_code_skills`
Whether standards are provided as Claude Code Skills.

**Usage:**
```markdown
{{UNLESS standards_as_claude_code_skills}}
This content appears only if standards are NOT using Skills.
{{ENDUNLESS standards_as_claude_code_skills}}
```

### `claude_code_commands`
Whether Claude Code commands are enabled.

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

### Example 1: Conditional Subagent Instructions

```markdown
{{IF use_claude_code_subagents}}
### Delegate to Subagents

Loop through each task group and delegate to the assigned subagent.

For each delegation, provide:
- The task group details
- The spec file
- Relevant standards
{{ENDIF use_claude_code_subagents}}

{{UNLESS use_claude_code_subagents}}
### Generate Prompts

Create prompt files for each task group in the implementation/prompts/ folder.
{{ENDUNLESS use_claude_code_subagents}}
```

### Example 2: Conditional Standards Handling

```markdown
{{UNLESS standards_as_claude_code_skills}}
## Apply Standards

Ensure your implementation follows these standards:

{{workflows/implementation/compile-standards}}

[List of compiled standards]
{{ENDUNLESS standards_as_claude_code_skills}}
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

- Uses `use_claude_code_subagents` to delegate or generate prompts
- Uses `standards_as_claude_code_skills` to handle standards
- References workflows like `{{workflows/implementation/compile-standards}}`
- Adapts behavior completely based on configuration

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
