## Workflow Interaction Standard

**When executing workflows that require user input, you MUST follow this structured interaction pattern.**

---

### 1. List All Questions Upfront

At workflow start, show ALL questions that will be asked:

```
I'll guide you through 4 questions:

1. **Topic** - Brief description
2. **Topic** - Brief description  
3. **Topic** - Brief description
4. **Topic** - Brief description

Let's begin!
```

---

### 2. Present Options in Consistent Format

Every question MUST use this exact format:

```
### Question X of Y: [Topic]

**A: [Option Title]** (Recommended)
   One-line description of this option

**B: [Option Title]**
   One-line description of this option

**C: [Option Title]** (Advanced)
   One-line description of this option

**D: Not Sure / Need Help**
   I'll help you determine the best approach

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

**Required Elements:**
- Progress indicator: `Question X of Y`
- Bold option format: `**A: Title**`
- Recommendation markers: `(Recommended)`, `(Most Common)`, `(Advanced)`
- One-line description indented below each option
- Clear instruction with 'go X' format
- Help/clarification option as last choice

---

### 3. Order Options by Recommendation

1. **Most recommended** - Best for typical use case
2. **Common alternatives** - Valid for different scenarios  
3. **Advanced/rare options** - For specific needs
4. **Help option** - Always last

---

### 4. Dynamic Option Refinement

**CRITICAL:** If user provides context, guidance, or corrections instead of selecting an option:

1. **Acknowledge** their input enthusiastically
2. **Refine** options based on their specific needs
3. **Add** new options if their context reveals better alternatives
4. **Re-order** by relevance to their situation
5. **Re-present** the updated options

**Example:**
```
User: "I need real-time updates and offline support"

Agent: "Great insight! For real-time + offline, here are better options:

**A: [New option tailored to their needs]** (Recommended)
   [Why this fits their requirements]

**B: [Refined previous option]**
   [Adjusted description]
..."
```

**Rules:**
- NEVER ignore user context
- NEVER proceed with assumption if they give guidance
- ALWAYS refine and re-present with their needs prioritized
- Keep good previous options if still relevant

---

### 5. Echo Back After Each Choice

Confirm understanding after each selection:

```
✓ **[Topic]:** [Their choice with brief context]

Moving to next question...
```

---

### 6. Use Warp-Friendly Commands

Support these commands:
- `go A`, `go B`, `go C` - Select option
- `skip` - Skip optional questions
- `back` - Previous question  
- `exit` - Exit workflow
- `summary` - Show choices so far
- `help` - More context about options

---

### 7. Handle Unexpected Input

If input is unclear, re-present options with clarification:

```
I didn't quite understand that. Let me re-present the options:

[Show options again with same format]
```

**Never:**
- Assume what they meant
- Pick a default silently
- Move forward with uncertainty

---

### 8. Provide Summary Before Proceeding

After all questions, show recap with confirmation:

```
## Review Your Choices

1. **[Topic]:** [Choice]
2. **[Topic]:** [Choice]
3. **[Topic]:** [Choice]

**A: Looks Good - Proceed**
   Continue with these choices

**B: Modify**
   Change one or more answers

**C: Start Over**
   Clear and restart

---
Type 'go A', 'go B', or 'go C'
```

---

### 9. Always Include Exit Options

Provide a way out of any workflow:

```
**E: Exit Workflow**
   Save progress and return later
```

---

## Quick Reference Checklist

Before each question, verify:
- [ ] Progress indicator present (X of Y)
- [ ] Options labeled A, B, C...
- [ ] Recommendation markers added
- [ ] Options ordered by suitability
- [ ] One-line descriptions included
- [ ] Help option included
- [ ] Clear 'go X' instruction
- [ ] Ready to refine if user provides context

After each answer:
- [ ] Echo back their choice
- [ ] Acknowledge with ✓

At workflow end:
- [ ] Show complete summary
- [ ] Offer review/modify option

---

## Anti-Patterns - DO NOT DO THIS

❌ Open-ended questions without options
❌ Assuming or guessing user intent
❌ Ignoring user context when they provide guidance
❌ Moving forward with unclear input
❌ Skipping progress indicators
❌ Forgetting the help/clarification option
❌ Using inconsistent option formatting

---

**For detailed examples and edge cases, reference:**
`docs/INTERACTION-GUIDELINES.md`
