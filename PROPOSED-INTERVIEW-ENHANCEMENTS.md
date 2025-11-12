# Proposed Interview Enhancements

## Summary of Changes

To address the three requirements:
1. **Support open-ended questions** (for planning questions that don't fit multiple choice)
2. **More verbose option descriptions** (multi-line explanations when needed)
3. **Clarification questions** (follow-ups between main questions)

---

## 1. Enhance `workflow-interaction.md`

**File:** `profiles/default/standards/global/workflow-interaction.md`

### Change 1.1: Replace Section 2 with Enhanced Question Types

**Current:** Section 2 only supports multiple choice format

**Proposed:** Split into three sub-sections:

#### 2a. Multiple Choice Questions (Enhanced)

```markdown
### 2a. Multiple Choice Questions

For questions where discrete options are appropriate:

```
### Question X of Y: [Topic]

**A: [Option Title]** (Recommended)
   Primary description line
   → Additional context, benefit, or use case
   → When this works best (optional)

**B: [Option Title]**
   Primary description line
   → Key differentiator
   → Example scenario (optional)

**C: [Option Title]** (Advanced)
   Primary description line
   → Technical detail or caveat

**D: Not Sure / Need Help**
   I'll help you determine the best approach

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

**Option Description Guidelines:**
- **Simple questions:** One line is sufficient
- **Complex decisions:** Add 1-3 sub-lines with → for additional context
- Keep descriptions scannable—avoid walls of text
- Use → prefix for sub-points to maintain visual hierarchy
```

#### 2b. Open-Ended Questions (NEW)

```markdown
### 2b. Open-Ended Questions

For questions requiring detailed, thoughtful responses:

```
### Question X of Y: [Topic]

[Clear question or prompt that invites detailed response]

**Consider:**
- [Aspect to think about 1]
- [Aspect to think about 2]
- [Aspect to think about 3]

**Example responses:**
- [Brief example 1]
- [Brief example 2]

---
Please provide your response below:
```

**When to use open-ended format:**
- Initial conceptual questions ("Describe your product idea")
- Planning/strategy discussions that need nuance
- Questions where the user's unique context is essential
- Situations where predefined options would be limiting

**After open-ended response:**
- Always acknowledge and summarize their answer with ✓
- May ask 1-3 clarification questions (see section 2c)
- Then proceed to next main question

**Transition to multiple choice:**
- If appropriate, follow open-ended questions with related multiple choice questions
- Example: Open Q1 "Describe your product" → Multiple choice Q2 "What's your target platform?"
```

#### 2c. Clarification Questions (NEW)

```markdown
### 2c. Clarification Questions

Between main questions, you may ask 1-3 brief clarifying questions:

```
✓ **[Topic]:** [Summary of their initial answer]

Before we continue, I have a few quick clarifications:

**Q1:** [Focused clarification question]

**Q2 (Optional):** [Second clarification if needed]

---
Respond naturally, or type 'next' to skip and continue to question [X+1]
```

**Guidelines:**
- Maximum 3 clarifications between main questions
- Mark optional clarifications clearly
- Use natural language responses (not multiple choice)
- Allow 'next'/'skip' commands to bypass clarifications
- Keep questions focused and brief
- Don't number clarifications as main questions

**When to use clarifications:**
- After open-ended responses that need elaboration
- When the answer impacts subsequent question options
- To gather specific details before proceeding
- To resolve ambiguity without creating a full main question

**After clarifications:**
- Summarize the complete understanding
- Echo back: ✓ **[Topic]:** [Updated summary with clarifications]
- Then proceed to next main question
```

---

## 2. Enhance `INTERACTION-GUIDELINES.md`

**File:** `docs/INTERACTION-GUIDELINES.md`

### Change 2.1: Update Anti-Pattern Section

**Current line ~360:** States "Don't ask open-ended questions without options"

**Proposed replacement:**

```markdown
## Anti-Patterns to Avoid

❌ **Don't ask vague questions without guidance**
```markdown
What do you want to build?
```

✅ **Do provide structure—even for open-ended questions**
```markdown
### Question 1 of 4: Product Vision

Describe the product you want to build.

**Consider:**
- What problem does it solve?
- Who are the primary users?
- What makes it unique or valuable?

**Example responses:**
- "A task manager for remote teams that works offline and syncs across devices"
- "An analytics dashboard that helps small businesses understand their customer behavior"

---
Please provide your response below:
```

---

❌ **Don't force multiple choice when open-ended is better**
```markdown
**A: Task Management App**
**B: Analytics Dashboard**
**C: Social Network**
**D: Something else** ← Forces user to pick wrong category
```

✅ **Do use open-ended for initial exploration, then narrow with multiple choice**
```markdown
Question 1 (Open): Describe your product concept
Question 2 (Multiple choice): Which platform will you target first?
```

---

❌ **Don't ask multiple choice for creative/planning questions**
```markdown
### Question 1: What's your product vision?
**A: Build something innovative**
**B: Solve a common problem**
**C: Create a business tool**
← These options are meaningless
```

✅ **Do use open-ended for vision/planning**
```markdown
### Question 1 of 5: Product Vision

Describe what you want to build and the problem it solves.

**Consider:**
- What frustration or need are you addressing?
- Who experiences this problem?
- What would an ideal solution look like?

---
Please provide your response below:
```
```

### Change 2.2: Add New Section on Question Type Selection

Add after section 11:

```markdown
### 12. **Choosing the Right Question Type**

Use this decision tree to determine which question format to use:

#### Use Open-Ended Questions When:
- Initial vision/concept exploration (Q1 of a planning workflow)
- Describing complex, unique situations
- User needs to provide creative input
- Predefined options would be limiting or presumptive
- Answer requires explanation or context

**Examples:**
- "Describe your product idea and the problem it solves"
- "What are the main workflows your users will follow?"
- "Explain the technical constraints or requirements for this project"

#### Use Multiple Choice Questions When:
- Selecting from known options (frameworks, databases, deployment)
- Making binary or categorical decisions
- User might benefit from seeing common patterns
- Answer affects subsequent question flow
- Providing recommendations or guidance

**Examples:**
- "Which database will you use?"
- "Do you want to start with an MVP or full feature set?"
- "What's your preferred authentication method?"

#### Use Clarification Questions When:
- Following up on open-ended responses
- Resolving ambiguity before proceeding
- Gathering specific details without creating full questions
- Answer impacts how you'll present next question's options

**Examples:**
- After "build a social app" → "Q: Will this be mobile-first or web-first?"
- After "need real-time features" → "Q: How many concurrent users do you expect?"

#### Mix Question Types in Workflows:
Good workflow progression:
1. Open-ended: Vision/concept
2. Clarification: Key details
3. Multiple choice: Technical decisions
4. Multiple choice: Preferences
5. Multiple choice: Scope/timeline

**Example:**
```markdown
Q1 (Open): Describe your product and the problem it solves
  → Clarification: "How many users do you expect?"
Q2 (Multiple choice): Which platform will you target first?
Q3 (Multiple choice): What's your preferred tech stack?
Q4 (Multiple choice): MVP or full feature set?
```
```

---

## 3. Update `gather-product-info.md` Implementation

**File:** `profiles/default/workflows/planning/gather-product-info.md`

### Change 3.1: Convert Question 1 (Project Type) to Open-Ended

**Current:** Multiple choice A/B/C/D for project type
**Problem:** First planning question is too constraining

**Proposed replacement for Step 2:**

```markdown
### Step 2: Question 1 - Product Vision (Open-Ended)

```
### Question 1 of 4: Product Vision

Describe the product you want to build.

**Consider:**
- What problem does this solve?
- Who are the primary users?
- What makes this solution unique or valuable?

**Example responses:**
- "A mobile app that helps freelancers track time and generate invoices, solving the problem of scattered tools and manual invoice creation"
- "An internal dashboard for our sales team to visualize pipeline metrics in real-time, currently they use spreadsheets which are always outdated"

---
Please provide your response below:
```

**After Response:** Ask 2-3 clarification questions:

```
✓ **Product Vision:** [Brief 1-line summary of their response]

Before we continue, a few quick clarifications:

**Q1:** Is this a new project starting from scratch, or are you adding to existing code?

**Q2 (Optional):** Roughly how many users do you expect in the first 6 months?

---
Respond naturally, or type 'next' to continue to question 2
```

After clarifications, echo back complete understanding:
```
✓ **Product Vision:** [Updated summary incorporating clarifications]

Moving to question 2...
```
```

### Change 3.2: Add Verbose Descriptions to Question 4 (Tech Stack)

**Current:** Single-line descriptions
**Problem:** Tech stack decisions are complex and need more context

**Proposed enhancement for Step 5:**

```markdown
### Step 5: Question 4 - Tech Stack

```
### Question 4 of 4: Tech Stack

What technologies will you use for this product?

**A: My Standard Stack** (Most Common)
   Use the tech stack from my project standards
   → Faster development, familiar patterns, documented preferences
   → Best when: You have established preferences you're happy with

**B: Custom Stack**
   Different technologies for this specific project
   → Tailored to project requirements, might include new tools
   → Best when: Project has unique needs or you want to try new tech

**C: Help Me Choose**
   I need recommendations based on my requirements
   → I'll analyze your product and suggest appropriate stack
   → Best when: Unsure what fits or want expert guidance

**D: Undecided for Now**
   I'll decide this later during planning
   → Focus on product vision first, tech decisions can wait
   → Best when: Still exploring concept, not ready for technical choices

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```
```

---

## 4. Update Question Overview in gather-product-info.md

**File:** `profiles/default/workflows/planning/gather-product-info.md`

### Change 4.1: Update Step 1 to Reflect New Question Types

**Current:**
```markdown
I'll guide you through 4 questions to gather comprehensive product information:

1. **Project Type** - Are you starting fresh or working with existing code?
2. **Product Concept** - What problem does this solve and for whom?
3. **Key Features** - What are the essential capabilities?
4. **Tech Stack** - What technologies will you use?
```

**Proposed:**
```markdown
I'll guide you through 4 questions to gather comprehensive product information:

1. **Product Vision** - Describe your product idea and what problem it solves
2. **Product Concept** - How you'd like to articulate your concept in detail
3. **Key Features** - What are the essential capabilities?
4. **Tech Stack** - What technologies will you use?

Let's begin!
```

---

## Summary of Files to Modify

1. **`profiles/default/standards/global/workflow-interaction.md`**
   - Enhance section 2 with three sub-sections (2a, 2b, 2c)
   - Add guidelines for verbose option descriptions
   - Add new clarification question pattern

2. **`docs/INTERACTION-GUIDELINES.md`**
   - Update anti-patterns section (remove "never open-ended" rule)
   - Add new section 12: "Choosing the Right Question Type"
   - Add examples of open-ended + clarification flow

3. **`profiles/default/workflows/planning/gather-product-info.md`**
   - Convert Question 1 to open-ended format
   - Add clarification questions after Question 1
   - Enhance Question 4 descriptions with verbose multi-line format
   - Update question overview in Step 1

---

## Benefits of These Changes

1. **More Natural First Question**: Planning starts with open exploration rather than forcing categorization
2. **Better Context Gathering**: Clarification questions fill gaps without creating heavy workflows
3. **Clearer Complex Options**: Verbose descriptions help users make informed decisions
4. **Flexible Interview Flow**: Mix of open-ended and multiple choice fits different question types
5. **Maintains Structure**: Still guided and Warp-friendly, just more adaptable

---

## Migration Notes

- Existing workflows with all multiple-choice questions still work fine
- New workflows can adopt open-ended + clarification patterns
- The `go A/B/C` pattern remains for multiple choice consistency
- Natural language responses for open-ended and clarifications
