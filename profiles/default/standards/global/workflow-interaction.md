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

### 2. Question Types

#### 2a. Multiple Choice Questions

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

**Required Elements:**
- Progress indicator: `Question X of Y`
- Bold option format: `**A: Title**`
- Recommendation markers: `(Recommended)`, `(Most Common)`, `(Advanced)`
- Primary description line + optional extended details (using →)
- Clear instruction with 'go X' format
- Help/clarification option as last choice

**Option Description Guidelines:**
- **Simple questions:** One line is sufficient
- **Complex decisions:** Add 1-3 sub-lines with → for additional context
- Keep descriptions scannable—avoid walls of text
- Use → prefix for sub-points to maintain visual hierarchy

#### 2b. Open-Ended Questions

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

#### 2c. Clarification Questions

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

### 10. Audit Trail Logging

**CRITICAL:** Every workflow execution must create an audit trail in the `.bot\audit\` directory.

#### Audit Trail Structure

Each workflow session creates a record at:
```
.bot/audit/workflows/<workflow-name>/<timestamp>-session.json
```

**Required fields in audit record:**

```json
{
  "session_id": "unique-identifier",
  "workflow_name": "workflow-identifier",
  "started_at": "ISO-8601-timestamp",
  "completed_at": "ISO-8601-timestamp or null",
  "status": "completed|abandoned|errored",
  "questions": [
    {
      "question_number": 1,
      "total_questions": 4,
      "type": "multiple_choice|open_ended|clarification",
      "topic": "Topic Name",
      "question_text": "Full question as presented",
      "options": [
        {"label": "A", "text": "Option text"},
        {"label": "B", "text": "Option text"}
      ],
      "user_response": "A or free-text response",
      "response_timestamp": "ISO-8601-timestamp",
      "response_time_seconds": 45
    }
  ],
  "metadata": {
    "user_id": "identifier or 'anonymous'",
    "warp_session_id": "warp-context-if-available",
    "environment": "dev|staging|prod",
    "client_version": "agent-version"
  },
  "exit_reason": "completed|user_exit|error|abandoned",
  "error_details": null
}
```

#### Logging Requirements

**During execution:**
- Log each question immediately before presenting it
- Log user response immediately after receiving it
- Include response_time_seconds for UX analytics
- Capture any clarification questions and responses

**After completion:**
- Record completed_at timestamp and final status
- If workflow exits early, log exit_reason and any error_details
- Ensure audit file is persisted atomically (write complete, then rename)

**Error handling:**
- If audit logging fails, log error but continue workflow (don't block user)
- Attempt to write a partial record with error details
- Don't expose audit logging errors to end user

#### Audit Trail Usage

- **Analytics**: Track user decisions, completion rates, time spent
- **Support**: Reconstruct exact workflow path for troubleshooting
- **Compliance**: Maintain records of questions asked and answers given
- **Debugging**: Identify where users get stuck or abandon workflows

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
- [ ] Log question and response to audit trail with timestamp

At workflow end:
- [ ] Show complete summary
- [ ] Offer review/modify option
- [ ] Finalize and persist audit trail record
- [ ] Record completion status and timestamp

Audit Trail:
- [ ] Session created with unique ID at workflow start
- [ ] Each question logged before presentation
- [ ] Each response logged with timestamp and response time
- [ ] Metadata captured (user, environment, version)
- [ ] Exit reason recorded
- [ ] Atomic persistence (avoid partial/corrupted records)

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
