# Template Variables Implementation in dotbot

## Overview

Template variables have been fully implemented in dotbot. The system processes template variables and conditional blocks at file installation time, adapting content based on configuration.

## Architecture

### Components

1. **Template-Processor.psm1** - Core processing engine
   - Located in `scripts/Template-Processor.psm1`
   - Handles conditional block parsing (IF/UNLESS/ENDIF/ENDUNLESS)
   - Processes variable substitution
   - Manages file references

2. **Common-Functions.psm1** - Integration layer
   - Imports Template-Processor module
   - Modified `Copy-DotbotFile` to process templates during file copy
   - Passes template variables through the file copy pipeline

3. **project-install.ps1** - Installation script
   - Builds template variable context from configuration
   - Passes context to all file installation functions
   - Ensures consistent processing across standards, workflows, agents, and commands

## How It Works

### Step 1: Configuration Loading
When `project-install.ps1` runs, it:
- Loads `config.yml` from the base dotbot installation
- Extracts configuration values for templates
- Builds a hashtable of variables

```powershell
$script:TemplateVariables = @{
    warp_commands = $true
    standards_as_warp_rules = $false
    profile = "default"
}
```

### Step 2: File Installation with Processing
During file copying, `Copy-DotbotFile` is called with:
- Source file path
- Destination path
- Template variable context
- Profile and base directory info

```powershell
Copy-DotbotFile -Source $source -Destination $dest `
    -TemplateVariables $script:TemplateVariables `
    -Profile $script:EffectiveProfile `
    -BaseDir $BaseDir
```

### Step 3: Template Processing
The `Invoke-ProcessTemplate` function:
1. **Processes conditionals** - Removes unwanted blocks based on variables
2. **Processes file references** - Embeds referenced file content
3. **Processes substitutions** - Replaces variable placeholders with values

```
Original File
    ↓
[Remove conditional blocks]
    ↓
[Embed file references]
    ↓
[Substitute variables]
    ↓
Processed File (installed in project)
```

## Template Syntax

### Conditional Blocks

#### IF Block
Shows content only when condition is true:

```markdown
{{IF warp_commands}}
This section appears when warp_commands is true
{{ENDIF warp_commands}}
```

#### UNLESS Block
Shows content only when condition is false:

```markdown
{{UNLESS standards_as_warp_rules}}
This section appears when standards_as_warp_rules is false
{{ENDUNLESS standards_as_warp_rules}}
```

#### Nested Conditions
Blocks can be nested and conditions are evaluated based on parent state:

```markdown
{{IF warp_commands}}
This appears when warp_commands is true

{{IF standards_as_warp_rules}}
This appears only when BOTH warp_commands AND standards_as_warp_rules are true
{{ENDIF standards_as_warp_rules}}

{{ENDIF warp_commands}}
```

### Variable Substitution

Replace `{{variable_name}}` with actual values:

```markdown
Profile: {{profile}}
Version: {{version}}
Base Directory: {{base_dir}}
```

**Note:** Boolean variables (used in conditionals) are NOT substituted.

### File References

Include content from other files:

```markdown
{{workflows/implementation/implement-tasks}}
{{standards/coding-style}}
```

## Available Variables

Current variables in template context:

- `warp_commands` (boolean) - Whether Warp integration is enabled
- `standards_as_warp_rules` (boolean) - Whether standards are in WARP.md
- `profile` (string) - Active profile name (e.g., "default", "rails")

These can be extended in `project-install.ps1` by modifying the template variable initialization.

## Processing Order

Templates are processed in this strict order:

1. **Conditionals first** - IF/UNLESS blocks are evaluated and content is included/excluded
2. **File references** - {{workflows/...}} placeholders are replaced with file content
3. **Variable substitution** - {{variable}} placeholders are replaced with values

This order ensures that:
- Conditions can control whether file references are included
- File content is processed recursively
- Substitutions happen on fully processed content

## Examples

### Example 1: Profile-Specific Content

```markdown
# {{profile}} Project Setup

This project uses the **{{profile}}** profile.

{{IF warp_commands}}
## Warp Commands Available
You can use Warp slash commands for this project.
{{ENDIF warp_commands}}

{{UNLESS warp_commands}}
## Standard Commands
Use the standard dotbot command interface.
{{ENDUNLESS warp_commands}}
```

### Example 2: Conditional Standards

```markdown
## Code Standards

{{IF standards_as_warp_rules}}
Standards are integrated into WARP.md as project rules.
See WARP.md for the full standards reference.
{{ENDIF standards_as_warp_rules}}

{{UNLESS standards_as_warp_rules}}
Standards are stored in separate files:

{{standards/coding-style}}

{{standards/documentation}}

{{ENDUNLESS standards_as_warp_rules}}
```

### Example 3: File Embedding

```markdown
# Implementation Workflow

Follow these phases:

{{workflows/implementation/planning}}

{{workflows/implementation/implementation}}

{{workflows/implementation/verification}}
```

## Testing

Comprehensive tests are included in `tests/Template-Processor.Tests.ps1`:

```powershell
Invoke-Pester tests/Template-Processor.Tests.ps1
```

Tests cover:
- ✅ IF/UNLESS conditional blocks
- ✅ Nested conditionals
- ✅ Variable substitution with special characters
- ✅ Multiple variable occurrences
- ✅ Boolean variable handling
- ✅ Block delimiter removal

All 12 tests pass successfully.

## Error Handling

### Missing Variables
If a variable is used in conditionals but not defined:
- A warning is logged
- The condition is treated as false
- Processing continues

### Missing File References
If a referenced file doesn't exist:
- A warning message is inserted instead of the file content
- Processing continues
- ⚠️ indicator shows where file was not found

### Malformed Blocks
If IF/UNLESS/ENDIF/ENDUNLESS blocks are unmatched:
- Blocks are processed based on nesting level
- Stack-based tracking prevents corruption
- Orphaned blocks are left as-is

## Extensibility

### Adding New Variables

1. Update `project-install.ps1` Initialize-Configuration:
```powershell
$script:TemplateVariables = @{
    warp_commands = $true
    standards_as_warp_rules = $script:EffectiveStandardsAsWarpRules
    profile = $script:EffectiveProfile
    new_variable = $someValue  # ← Add here
}
```

2. Use in templates:
```markdown
{{IF new_variable}}
Content for new variable
{{ENDIF new_variable}}
```

### Adding New File Reference Types

Currently supported:
- `{{workflows/...}}`
- `{{standards/...}}`
- `{{commands/...}}`
- `{{agents/...}}`

To add more, update the regex in `Invoke-ProcessFileReferences`:
```powershell
$references = [regex]::Matches($result, '\{\{((?:workflows|standards|commands|agents|new_type)/[^}]+)\}\}')
```

## Performance

- Conditionals: O(n) single pass through content
- File references: O(m) where m = number of references
- Variable substitution: O(k) where k = number of variables

Total: Linear time complexity relative to content size and variable count.

## Migration from Old System

Previous system stored raw template files in projects. New system:
- ✅ Processes files at installation time
- ✅ Only stores final output in project
- ✅ Allows different configurations for different projects
- ✅ Cleaner git history (no template artifacts)

To migrate existing projects:
```powershell
dotbot init --re-install --profile default
```

## Troubleshooting

### Templates not being processed

**Symptom:** Template syntax appears in installed files

**Solution:**
1. Check that template variables are being passed:
   ```powershell
   $script:TemplateVariables  # Should not be empty
   ```
2. Verify variables match template syntax
3. Run with verbose flag:
   ```powershell
   dotbot init --verbose
   ```

### File references not embedding

**Symptom:** "{{workflows/..." appears in installed files

**Solution:**
1. Check file exists at: `~/dotbot/profiles/{profile}/{path}.md`
2. Verify relative path format (no leading/trailing slashes)
3. Check for circular references

### Conditionals not working

**Symptom:** Content appears when it shouldn't (or vice versa)

**Solution:**
1. Verify variable names use lowercase and underscores: `warp_commands` not `WarpCommands`
2. Check block closing tags match opening tags
3. Verify boolean values are `$true` or `$false` in configuration

## Future Enhancements

Potential improvements:
- [ ] Variable expressions (e.g., `{{variable1 && variable2}}`)
- [ ] Filters/transformations (e.g., `{{profile | uppercase}}`)
- [ ] Loops for multiple file references
- [ ] Configuration file validation schema
- [ ] IDE syntax highlighting support
- [ ] Template preview generation
