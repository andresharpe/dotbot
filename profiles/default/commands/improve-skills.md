# Improve Skills Command

Optimize Claude Code Skills descriptions for better discoverability and usage by AI agents.

## Description

This command helps you improve Claude Code Skills by rewriting their descriptions to make them more discoverable and usable. It:
- Analyzes existing skill files
- Rewrites descriptions for better Claude Code integration
- Adds "When to use" sections
- Follows Claude Code best practices

## When to Use

Use this command when you:
- Have created Claude Code Skills that aren't being used enough
- Want to optimize skill discoverability
- Need to improve skill descriptions
- Are setting up Skills for the first time
- Notice agents aren't finding relevant skills

## Reference

Claude Code Skills documentation: https://docs.claude.com/en/docs/claude-code/skills

## Process

### Step 1: Confirm Which Skills to Improve

Ask the user:
```
Before I proceed with improving your Claude Code Skills, can you confirm that you want me to revise and improve ALL Skills in your .claude/skills/ folder?

If not, then please specify which Skills I should include or exclude.
```

Wait for user response.

### Step 2: Analyze Each Skill

For each skill file in `.claude/skills/[skill-name]/SKILL.md`:

1. **Read the skill file** to understand:
   - The skill's name and purpose
   - What it should be used for
   - When it should be triggered
   - The linked standards or documentation

2. **Identify the core capability** this skill provides

3. **Note current description** and its limitations

### Step 3: Rewrite the Skill Description

Improve the `description` field in the frontmatter using these guidelines:

**First Sentence:**
- Clearly describe what this skill does
- Example: "Write Tailwind CSS code and structure front-end UIs using Tailwind CSS utility classes."

**Subsequent Sentences:**
- Describe multiple examples where and when this skill should be used
- Include file types: "When writing or editing .tsx, .jsx, .vue files"
- Include situations: "When creating responsive layouts", "When styling components"
- Include tools: "When working with React components", "When building UIs"

**Guidelines:**
- Be descriptive and specific
- Focus on WHEN to use (not when NOT to use)
- No maximum length - be thorough
- Use concrete examples
- Make it searchable

**Example:**
```markdown
---
description: "Write and manage database migrations for schema changes. Use when creating or modifying database tables, columns, indexes, or constraints. Use when setting up new models or changing existing data structures. Apply when working with .sql files, migration files, or ORM schema definitions."
---
```

### Step 4: Add "When to Use This Skill" Section

Below the frontmatter, insert:

```markdown
## When to use this skill:

- [Descriptive example A]
- [Descriptive example B]
- [Descriptive example C]
```

Examples should be:
- Specific situations
- File types being worked on
- Features being built
- Problems being solved

### Step 5: Advise on Further Improvements

After revising all skills, display:

```
All Claude Code Skills have been analyzed and revised!

RECOMMENDATION 👉 Review and revise them further using these tips:

- Make Skills as descriptive as possible
- Use their 'description' frontmatter to tell Claude Code when it should proactively use this skill
- Include all relevant instructions, details and directives within the content of the Skill
- You can link to other files (like your dotbot standards files) using markdown links
- You can consolidate multiple similar skills into single skills where it makes sense

For more best practices, refer to the official Claude Code documentation on Skills:
https://docs.claude.com/en/docs/claude-code/skills
```

## Output

Updated skill files with:
- Improved, descriptive frontmatter descriptions
- Clear "When to use" sections
- Better discoverability for Claude Code
- Concrete examples of usage scenarios

## Example Before/After

### Before:
```markdown
---
description: "CSS styling"
---

Use this for CSS.
```

### After:
```markdown
---
description: "Write and apply Tailwind CSS utility classes for styling UI components. Use when creating responsive layouts, styling React/Vue components, or working with .tsx, .jsx, .vue files. Apply when building forms, cards, navigation, modals, or any visual UI elements. Use when you need to implement designs with utility-first CSS approach."
---

## When to use this skill:

- When styling React or Vue components
- When working with .tsx, .jsx, or .vue files
- When implementing responsive layouts
- When creating UI components like forms, cards, modals
- When applying hover states, focus states, or animations
- When building navigation menus or layouts
```

## Tips

- Be specific about file types and situations
- Think about how agents search for relevant skills
- Include technical terms and framework names
- Expand descriptions rather than being concise
- Test by checking if skills appear in relevant contexts
- Review Claude Code's skill usage logs
