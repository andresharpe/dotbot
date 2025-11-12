# Interaction Guidelines

## Overview

These guidelines define how AI agents should interact with users during dotbot workflows. The goal is to create a **consistent, guided, and Warp-friendly** experience that minimizes cognitive load and maximizes clarity.

---

## Core Principles

### 1. **List Questions Upfront**
At the start of any workflow that requires multiple inputs, present ALL questions that will be asked:

```markdown
I'll guide you through 4 questions to gather the product information:

1. **Project Type** - Are you starting new or working with existing code?
2. **Core Product Idea** - What problem does this solve?
3. **Key Features** - What are the essential capabilities?
4. **Tech Stack** - Will you use your standard stack or customize?

Let's begin!
```

**Why:** Users can mentally prepare and gather needed information.

---

### 2. **Present Options in Consistent Format**
Every question should present options labeled **A, B, C, D**, etc. in this format:

```markdown
### Question 1 of 4: Project Type

Please choose how you want to proceed:

**A: New Product** (Recommended)
   Starting fresh with no existing codebase

**B: Existing Product**
   Adding to an established project

**C: Migration/Refactor**
   Updating or modernizing existing code

**D: Not Sure**
   Let me help you determine the best approach

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

**Format Rules:**
- Bold the option letter and title: `**A: Title**`
- Add recommendation markers: `(Recommended)`, `(Most Common)`, `(Advanced)`
- Include 1-line description indented below
- Order options by recommendation (best first)
- Always include a help/clarification option (usually last)
- End with clear instruction: "Type 'go X' to continue"

---

### 3. **Use Warp-Friendly Prompts**
All user actions should be simple, memorable commands:

| Command | Purpose |
|---------|---------|
| `go A`, `go B`, `go C` | Select an option |
| `skip` | Skip optional questions |
| `back` | Return to previous question |
| `exit` | Exit the workflow |
| `summary` | Show choices made so far |
| `help` | Get more context about options |

**Why:** Short commands are easy to type in Warp and feel natural.

---

### 4. **Order Options by Recommendation**
Present options in order of suitability:
1. **Most recommended** for typical use cases
2. **Common alternatives** for different scenarios
3. **Advanced or rare options**
4. **Help/clarification option** always last

**Example:**
```markdown
**A: REST API** (Recommended)
   Standard, well-supported, works everywhere

**B: GraphQL**
   Flexible queries, good for complex data needs

**C: gRPC** (Advanced)
   High performance, for microservices

**D: Not Sure**
   Let me help you choose
```

---

### 5. **Dynamic Option Refinement**

**CRITICAL:** If the user provides guidance, corrections, or additional context instead of selecting an option, you MUST:

1. **Acknowledge** their input
2. **Refine** the options based on their guidance
3. **Expand** with new options if needed
4. **Re-present** the updated options

**Example Interaction:**

**Agent:** 
```markdown
**A: REST API** (Recommended)
**B: GraphQL**
**C: gRPC**
---
Type 'go A', 'go B', or 'go C' to continue
```

**User:** "Actually, I need real-time updates and the API will be used by mobile apps with unreliable connections"

**Agent:**
```markdown
Thanks for that context! Given your need for real-time updates and mobile reliability, 
here are refined options:

**A: GraphQL with Subscriptions** (Recommended)
   Real-time via WebSockets, efficient for mobile with query flexibility

**B: REST with Server-Sent Events (SSE)**
   Simple real-time updates, good browser support, one-way communication

**C: WebSocket API**
   Full bidirectional communication, requires more infrastructure

**D: Firebase/Supabase Real-time**
   Managed solution, excellent offline support, fastest to implement

---
Type 'go A', 'go B', 'go C', or 'go D' to continue
```

**Rules for Refinement:**
- Never ignore or override user context
- Adjust recommendations based on new information
- Add new options if user reveals constraints
- Re-order by relevance to their specific needs
- Keep previous good options if still relevant

---

### 6. **Progress Indicators**
Show where the user is in multi-question workflows:

```markdown
### Question 2 of 5: Database Choice
```

**Why:** Reduces anxiety and helps users gauge time commitment.

---

### 7. **Acknowledge and Echo Back**
After each choice, confirm what was understood:

```markdown
✓ **Project Type:** New Product (greenfield development)

Moving to next question...
```

**Why:** Builds confidence and catches misunderstandings early.

---

### 8. **Provide Exit Options**
Always include a way out:

```markdown
**E: Exit Workflow**
   Save progress and return later

---
Type 'go A', 'go B', 'go C', 'go D', or 'exit' to leave
```

**Why:** Users should never feel trapped in a workflow.

---

### 9. **Handle Unexpected Input**
If user provides unclear input, re-present options with clarification:

```markdown
I didn't quite understand that. Let me re-present the options:

**A: PostgreSQL** (Recommended)
   [description]

**B: MySQL**
   [description]

**C: Something else**
   Please describe what you need

---
Type 'go A', 'go B', or 'go C'
```

**Never:**
- Assume what they meant
- Silently pick a default
- Move forward with uncertainty

---

### 10. **Offer Quick Defaults**
For experienced users, provide a fast-path:

```markdown
**D: Use Recommended Defaults**
   I'll use best-practice choices for remaining questions
   (You can review and modify afterward)
```

**Why:** Respects power users' time.

---

### 11. **Summary Before Proceeding**
After all questions, show a recap:

```markdown
## Review Your Choices

Let me confirm what we've gathered:

1. **Project Type:** New Product
2. **Core Idea:** Task management app for remote teams
3. **Key Features:** 
   - Real-time collaboration
   - Offline support
   - Mobile apps
4. **Tech Stack:** Custom (Next.js, Supabase, React Native)

**A: Looks Good - Proceed**
   Continue with these choices

**B: Modify**
   Change one or more answers

**C: Start Over**
   Clear all answers and restart

---
Type 'go A', 'go B', or 'go C'
```

---

## Complete Example Flow

Here's a full example of the pattern in action:

### Initial Setup
```markdown
I'll guide you through 3 questions to shape this spec:

1. **User Authentication** - How should users sign in?
2. **Data Storage** - Where should we store user data?
3. **UI Framework** - What should we use for the interface?

Let's begin!
```

### Question 1
```markdown
### Question 1 of 3: User Authentication

**A: Email + Password** (Recommended)
   Standard authentication, full control, works everywhere

**B: OAuth (Google, GitHub, etc.)**
   Social login, faster signup, less password fatigue

**C: Magic Links**
   Passwordless, email-based, very user-friendly

**D: Combination**
   Offer multiple methods

**E: Not Sure**
   Let me help you choose based on your users

---
Type 'go A', 'go B', 'go C', 'go D', or 'go E'
```

### User Input Variation 1 (Selects Option)
```
User: go B
```

**Agent Response:**
```markdown
✓ **Authentication:** OAuth (Google, GitHub, etc.)

Moving to question 2...
```

### User Input Variation 2 (Provides Context)
```
User: We're building for enterprise customers who need SSO and MFA
```

**Agent Response:**
```markdown
Perfect - enterprise SSO changes things! Here are better options:

**A: SAML 2.0 + MFA** (Recommended)
   Industry standard for enterprise SSO, supports Okta, Azure AD, Google Workspace

**B: OAuth 2.0 with PKCE + TOTP MFA**
   Modern approach, good for both enterprise and consumer

**C: Auth0 or Okta as Provider**
   Managed solution, handles SSO complexity, fastest implementation

**D: Custom OIDC Implementation**
   Maximum control, requires security expertise

---
Type 'go A', 'go B', 'go C', or 'go D'
```

---

## Implementation Checklist

When implementing these guidelines in a workflow, ensure:

- [ ] All questions listed upfront
- [ ] Each question has clear options (A, B, C...)
- [ ] Options ordered by recommendation
- [ ] Each option has 1-line description
- [ ] Recommendation markers present
- [ ] Progress indicators shown (X of Y)
- [ ] Clear 'go X' instructions
- [ ] Echo/confirmation after each choice
- [ ] Handle dynamic refinement if user provides context
- [ ] Summary/review before proceeding
- [ ] Exit options available

---

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

---

❌ **Don't assume or guess**
```markdown
I'll assume you want PostgreSQL since that's most common.
```

✅ **Do ask explicitly**
```markdown
**A: PostgreSQL** (Recommended)
**B: MySQL**
**C: Something else**
```

---

❌ **Don't ignore user context**
```markdown
User: "We need offline-first support"
Agent: Okay, proceeding with standard REST API...
```

✅ **Do refine based on context**
```markdown
User: "We need offline-first support"
Agent: Great insight! For offline-first, here are better options:
**A: Local-first with sync (PouchDB/CouchDB)**
**B: Service Workers with IndexedDB**
```

---

## Standards Reference

This interaction pattern should be followed by all agents when executing workflows. Reference this document in:

- `.bot/standards/global/workflow-interaction.md` (concise version for agents)
- All agent personas in `.bot/agents/`
- All interactive workflows in `.bot/workflows/`

---

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

---

## Feedback and Iteration

These guidelines will evolve based on user feedback. If you discover patterns that work better, document them here and update the workflows accordingly.
