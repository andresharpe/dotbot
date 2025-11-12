# Gather Product Info

**Agent:** @.bot/agents/product-planner.md

**Interaction Standard:** Follow `.bot/standards/global/workflow-interaction.md`

## Overview

Collect comprehensive product information through guided questions with options.

## Pre-Flight Check

Check if product folder already exists. If so:
- Review existing files (`.bot/product/mission.md`, `.bot/product/roadmap.md`, etc.)
- Understand what's already documented
- Ask if user wants to update existing product or start fresh

## Workflow

### Step 1: Present Question Overview

Show user all questions upfront:

```
I'll guide you through 4 questions to gather comprehensive product information:

1. **Product Vision** - Describe your product idea and what problem it solves
2. **Product Concept** - How you'd like to articulate your concept in detail
3. **Key Features** - What are the essential capabilities?
4. **Tech Stack** - What technologies will you use?

Let's begin!
```

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

**After Response:** Acknowledge and ask 2-3 clarification questions:

```
✓ **Product Vision:** [Brief 1-line summary of their response]

Before we continue, I have a few quick clarifications:

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

### Step 3: Question 2 - Product Concept

```
### Question 2 of 4: Product Concept

How would you like to describe your product idea?

**A: I'll Describe It Now**
   Tell me your product concept, target users, and the problem it solves

**B: Interactive Q&A**
   I'll ask you targeted questions to shape the concept

**C: Use Existing Documentation**
   I have a document or notes I can share

**D: Help Me Define It**
   I have a general idea but need help articulating it

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

**If they choose A:** Wait for their description

**If they choose B:** Ask targeted questions:
1. What problem does this solve?
2. Who are the primary users?
3. What makes this solution unique or valuable?
4. What's the core user journey or workflow?

**If they choose C:** Ask them to provide the documentation

**If they choose D:** Guide them with prompts:
- "Let's start with the problem. What frustration or need are you addressing?"
- "Who experiences this problem most?"
- "How do they solve it today (if at all)?"
- "What would an ideal solution look like?"

After capturing concept, echo back:
```
✓ **Product Concept:** [Brief summary of their idea]

Moving to question 3...
```

### Step 4: Question 3 - Key Features

```
### Question 3 of 4: Key Features

How would you like to define the key features (minimum 3)?

**A: List Them Now**
   I'll provide the feature list

**B: Brainstorm with Me**
   Help me identify must-have vs nice-to-have features

**C: Start with MVP**
   Focus on absolute essentials for first version

**D: Full Vision**
   Include all planned features across multiple phases

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

**If they choose A:** Wait for their feature list

**If they choose B:** Prompt:
- "Based on your concept, what's the ONE thing users absolutely need?"
- "What's the second most critical capability?"
- "What would make users choose this over alternatives?"
- "Are there any nice-to-have features on your mind?"

**If they choose C:** Guide to essentials:
- "For an MVP, what's the minimum users need to get value?"
- "What can you validate or learn with the least features?"
- "What would you cut if you had to launch in 2 weeks?"

**If they choose D:** Capture comprehensive vision:
- "What are all the features you envision, regardless of priority?"
- "Which ones are for Phase 1, Phase 2, Phase 3?"

After capturing features, echo back:
```
✓ **Key Features:** [List their 3+ main features]

Moving to question 4...
```

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

**If they choose A:** 
- Check for existing tech stack documentation
- Confirm: "I'll use the stack from `.bot/standards/global/tech-stack.md`" (if exists)
- If no docs exist, ask them to describe their standard stack briefly

**If they choose B:** Ask for details:
- Frontend technologies?
- Backend/API technologies?
- Database?
- Any other key technologies or platforms?

**If they choose C:** Recommend based on their product:
- Analyze their product type and features
- Suggest appropriate stack with rationale
- Present as options for them to choose

**If they choose D:** Note for later and continue

After capturing tech stack, echo back:
```
✓ **Tech Stack:** [Their choice or "To be determined"]

All questions answered!
```

### Step 6: Review Summary

```
## Review Your Product Information

Let me confirm what we've gathered:

1. **Product Vision:** [Their answer]
2. **Product Concept:** [Their answer]
3. **Key Features:**
   - [Feature 1]
   - [Feature 2]
   - [Feature 3]
   - [Additional features...]
4. **Tech Stack:** [Their answer]

**A: Looks Good - Proceed**
   Continue to create product mission and roadmap

**B: Modify**
   Change one or more answers

**C: Start Over**
   Clear all and restart from question 1

---
Type 'go A', 'go B', or 'go C'
```

**If A:** Proceed to next workflow (create-product-mission.md)

**If B:** Ask which question to revisit and present those options again

**If C:** Start over from Step 1

## Output

Information gathered is stored in memory for subsequent workflows. No files are created in this step.
