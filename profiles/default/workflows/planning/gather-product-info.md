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

1. **Project Type** - Are you starting fresh or working with existing code?
2. **Product Concept** - What problem does this solve and for whom?
3. **Key Features** - What are the essential capabilities?
4. **Tech Stack** - What technologies will you use?

Let's begin!
```

### Step 2: Question 1 - Project Type

```
### Question 1 of 4: Project Type

How would you describe this project?

**A: New Product** (Recommended)
   Starting fresh with no existing codebase

**B: New Feature for Existing Product**
   Adding functionality to an established project

**C: Refactor/Migration**
   Updating or modernizing existing code

**D: Not Sure**
   Let me help you determine the best classification

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

After response, echo back:
```
✓ **Project Type:** [Their choice]

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

**B: Custom Stack**
   Different technologies for this project

**C: Help Me Choose**
   I need recommendations based on my requirements

**D: Undecided for Now**
   I'll decide this later during planning

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

1. **Project Type:** [Their answer]
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
