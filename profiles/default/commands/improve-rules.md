# Improve Rules Command

Optimize Warp project rules in WARP.md for better clarity and agent effectiveness.

## Description

This command helps you improve project rules in your WARP.md file by:
- Analyzing existing rules
- Rewriting for clarity and specificity
- Adding context and examples
- Following Warp best practices

## When to Use

Use this command when you:
- Have created project rules that need refinement
- Want to make rules more specific and actionable
- Need to add examples to existing rules
- Are setting up WARP.md for the first time
- Notice the agent isn't following rules correctly

## Reference

Warp Project Rules documentation: https://docs.warp.dev/features/warp-ai/ai-command-search#project-rules

## Process

### Step 1: Review Current WARP.md

Read the project's `WARP.md` file to understand:
- Current project rules
- Any existing standards or conventions
- What's working and what needs improvement

If WARP.md doesn't exist, suggest creating one.

### Step 2: Analyze Each Rule

For each rule in WARP.md:

1. **Understand the intent** - What is this rule trying to achieve?
2. **Check clarity** - Is it clear and unambiguous?
3. **Look for examples** - Does it have concrete examples?
4. **Assess specificity** - Is it too vague or too prescriptive?

### Step 3: Rewrite Rules for Clarity

Improve each rule using these guidelines:

**Be Specific:**
- Bad: "Write good code"
- Good: "Use TypeScript for all new files. Add type annotations for function parameters and return values."

**Include Context:**
- Explain WHY the rule exists
- Example: "Use Tailwind CSS for styling (keeps bundle size small and maintains consistency)"

**Add Examples:**
```markdown
## Rule: Error Handling

All API calls must include error handling with user-friendly messages.

Example:
```typescript
try {
  const data = await fetchUser(id);
} catch (error) {
  showToast('Unable to load user. Please try again.');
  logError(error);
}
```
```

**Make Rules Actionable:**
- Use imperatives: "Always", "Never", "Prefer", "Avoid"
- Be directive: "Do X" not "Consider doing X"

### Step 4: Organize Rules Logically

Group related rules into sections:

```markdown
# Project Rules

## Code Style
- [Style rules]

## Architecture
- [Architecture rules]

## Testing
- [Testing rules]

## Git & Workflow
- [Workflow rules]
```

### Step 5: Add Standards References

Link to detailed standards:

```markdown
## Standards

For detailed standards, see:
- @.bot/standards/global/coding-style.md
- @.bot/standards/global/error-handling.md
- @.bot/standards/global/validation.md
```

### Step 6: Test Rules

Suggest testing the updated rules:
```
Updated WARP.md with improved project rules!

RECOMMENDATION 👉 Test these rules:

1. Ask Warp Agent to implement a feature
2. Check if it follows the rules
3. Refine rules that aren't being followed
4. Add examples for unclear rules

Best practices:
- Keep rules concise but complete
- Use examples liberally
- Update rules as project evolves
- Remove outdated rules promptly
```

## Output

An improved WARP.md with:
- Clear, specific rules
- Concrete examples for each rule
- Logical organization by category
- Context explaining why rules exist
- References to detailed standards

## Example Before/After

### Before:
```markdown
# Project Rules

Use TypeScript. Write tests.
```

### After:
```markdown
# Project Rules

## Code Style

### TypeScript Usage
Use TypeScript for all new files. Add type annotations for:
- Function parameters
- Function return values
- Complex objects and interfaces

Why: Type safety catches errors at compile time and improves IDE support.

Example:
```typescript
// Good
function calculateTotal(items: CartItem[]): number {
  return items.reduce((sum, item) => sum + item.price, 0);
}

// Avoid
function calculateTotal(items) {
  return items.reduce((sum, item) => sum + item.price, 0);
}
```

## Testing

### Test Coverage
Write unit tests for all business logic and utility functions.
- Use Jest as the test framework
- Aim for 80%+ code coverage
- Test happy paths and error cases

Example test structure:
```typescript
describe('calculateTotal', () => {
  it('should sum item prices', () => {
    const items = [{ price: 10 }, { price: 20 }];
    expect(calculateTotal(items)).toBe(30);
  });
  
  it('should return 0 for empty array', () => {
    expect(calculateTotal([])).toBe(0);
  });
});
```

## Standards

For detailed standards, see:
- @.bot/standards/global/coding-style.md
- @.bot/standards/global/error-handling.md
```

## Tips

- Make rules specific and actionable
- Include WHY, not just WHAT
- Add examples for complex rules
- Organize rules by category
- Keep rules updated as project evolves
- Remove rules that are no longer relevant
- Test rules by using them with Warp Agent

