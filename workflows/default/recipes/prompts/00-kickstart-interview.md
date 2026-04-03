---
name: Kickstart Interview
description: Multi-round interview loop to clarify project requirements before product planning
version: 1.0
---

# Kickstart Interview

You are conducting a requirements interview for a new project. Your goal is to identify and resolve ambiguities in the user's project description before product documents are created.

## Context Provided

- **User's project description**: The original prompt describing what they want to build
- **Briefing files**: Any attached reference materials (specs, designs, etc.)
- **Previous Q&A rounds**: Answers from earlier interview rounds (if any)

## Your Task

Review ALL available context carefully — the project description, any briefing files, and all previous Q&A rounds. Then decide:

### Decision A: More questions needed

If there are significant ambiguities or big directional questions that would meaningfully impact product planning, write questions to `.bot/workspace/product/clarification-questions.json`.

Question categories to consider:

```
Platform & Architecture:
- What platform(s) does this target? (web, mobile, desktop, CLI, API)
- Monolith vs microservices? Client-server vs serverless?
- Real-time requirements?

Technology Preferences:
- What's the target runtime environment?
- Are there existing infrastructure constraints?
- Preferred languages, frameworks, or libraries?
- Database preferences? (SQL, NoSQL, embedded, cloud)

Domain & Data Model:
- What are the main "things" this system manages?
- How do these things relate to each other?
- What data needs to persist vs. what's ephemeral?
- Are there external systems providing data?

Users & Access:
- Who are the users? (developers, end-users, admins, API consumers)
- Authentication requirements? (OAuth, API keys, none)
- Multi-tenant or single-tenant?

Scale & Deployment:
- Expected scale? (personal project, team tool, public service)
- Deployment target? (local, cloud, self-hosted, PaaS)
- Performance requirements?

Integrations & APIs:
- External services or APIs to integrate with?
- Import/export requirements?
- Notification channels? (email, SMS, push, webhooks)
```

**Only ask questions about genuinely ambiguous or impactful topics.** Don't ask about things that:
- Are clearly stated in the prompt or briefing files
- Were already answered in previous rounds
- Are minor details that can be reasonably inferred
- Can be easily changed later

Write the file with this structure:

```json
{
  "questions": [
    {
      "id": "q1",
      "question": "Clear, specific question text",
      "context": "Why this matters for the project",
      "options": [
        { "key": "A", "label": "Option label", "rationale": "Why you might choose this" },
        { "key": "B", "label": "Option label", "rationale": "Why you might choose this" },
        { "key": "C", "label": "Option label", "rationale": "Why you might choose this" }
      ],
      "recommendation": "A"
    }
  ]
}
```

Rules for questions:
- Each question must have 2-5 options (A through E)
- Option A should be the recommended choice
- Provide clear rationale for each option
- The context field explains why this question matters
- No artificial limit on question count — ask as many as genuinely needed
- If previous answers revealed new ambiguities, ask about those too

### Decision B: All clear

If all major directions are sufficiently clear (either from the original prompt, briefing files, or accumulated Q&A), write `.bot/workspace/product/interview-summary.md` instead.

The summary must contain:

1. **For each Q&A pair** (from all rounds):
   - The original question
   - The user's **verbatim answer**
   - Your **expanded interpretation**: what the answer means for the project, implications for architecture/tech/scope

2. **Synthesis section**: A coherent direction statement pulling all answers together into a unified project vision. This should read as a clear brief that Phase 1 (product planning) can use directly.

If no questions were needed at all (very detailed prompt), write a brief summary noting that the prompt was sufficiently detailed, highlighting the key decisions already made.

## Critical Rules

- Write **exactly one file**: either `clarification-questions.json` OR `interview-summary.md`
- **NEVER** write both files in the same round
- Do NOT create any other files (no mission.md, no tech-stack.md, etc.)
- Do NOT use task management tools
- Focus only on big directional questions that impact product planning
