---
name: Generate Decisions from Interview
description: Phase 1b — extract decisions from the interview and product documents into decision records
version: 1.0
---

# Generate Decisions

You are reviewing the outputs of the kickstart interview and product planning phase. Your job is to extract genuine decisions — architectural, business, technical, and process — and record them using the `decision_create` MCP tool.

## Session Context

- **Session ID:** {{SESSION_ID}}

## Instructions

### Step 1: Read Source Documents

Read all available source material:

```
Read({ file_path: ".bot/workspace/product/interview-summary.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
Read({ file_path: ".bot/workspace/product/tech-stack.md" })
Read({ file_path: ".bot/workspace/product/entity-model.md" })
```

### Step 2: Identify Decision-Worthy Choices

Scan the source documents for decisions that meet ALL of these criteria:

**Include:**
- Scope boundaries (what is explicitly in/out of scope and why)
- Platform or technology choices where alternatives existed
- Migration strategy decisions (e.g. like-for-like vs. rework)
- Integration decisions (which systems are included/deferred)
- Domain model choices that have architectural consequences
- Business constraints or priorities (budget, timeline, target audience trade-offs)
- Process choices (branching strategy, release cadence, review workflows)
- Any decision where the interview reveals a rejected alternative

**Exclude:**
- Clarifications that just confirmed an obvious default
- Questions the user skipped
- Implementation details that belong in task plans
- Generic principles without a real trade-off

Aim for **3–10 decisions** from a typical kickstart. Fewer is better than padding with non-decisions.

### Step 3: Create Decisions

For each identified decision, call `decision_create`. Set `status` to `accepted` (these decisions are already ratified by the interview process).

**Field guidance:**

- **title**: Short, noun-phrase title of the decision (not a question). E.g. "Scope to Titan Platform Only", not "Should we use Titan?"
- **context**: Why this decision needed to be made — the forces at play. Pull from the interview interpretation sections.
- **decision**: The specific choice made. Be concrete.
- **consequences**: Trade-offs, constraints this creates for future tasks, risks.
- **alternatives_considered**: What was evaluated and rejected, with reasons. Use structured format with option and reason_rejected.
- **type**: One of `architecture`, `business`, `technical`, or `process`.
- **impact**: The impact level of this decision (e.g. "high", "medium", "low").
- **tags**: Relevant tags for categorization and filtering.
- **related_decision_ids**: Link decisions that are logically connected (fill in after creating all of them).

**Example call:**

```javascript
mcp__dotbot__decision_create({
  title: "Scope Implementation to Titan Platform Only",
  context: "The project could target both Titan (the core billing platform) and FinApps (the financial applications layer). Including both would increase scope and risk significantly.",
  decision: "All implementation will target Titan only. FinApps integration is explicitly deferred.",
  consequences: "FinApps will continue to use the existing approach until a follow-on project. Tasks must not introduce FinApps dependencies. Acceptance criteria should validate Titan behaviour only.",
  alternatives_considered: [
    { option: "Both Titan and FinApps simultaneously", reason_rejected: "Increased complexity and risk of breaking FinApps billing during the migration" }
  ],
  status: "accepted",
  type: "architecture",
  impact: "high",
  tags: ["platform", "scope", "titan"]
})
```

### Step 4: Link Related Decisions

After creating all decisions, identify pairs that are logically related (e.g. "scope to Titan" relates to "defer FinApps integration"). Use `decision_update` to set `related_decision_ids` on each.

```javascript
mcp__dotbot__decision_update({
  decision_id: "dec-XXXXXXXX",
  related_decision_ids: ["dec-YYYYYYYY", "dec-ZZZZZZZZ"]
})
```

### Step 5: Report

Output a summary:
- Number of decisions created
- List of decision IDs and titles
- Any decisions you chose NOT to record and why

---

## MCP Tools

| Tool | Purpose |
|------|---------|
| `mcp__dotbot__decision_create` | Create a new decision |
| `mcp__dotbot__decision_update` | Update an existing decision (e.g. to add related_decision_ids) |
| `mcp__dotbot__decision_list` | List created decisions to review |

---

## Anti-Patterns

### ❌ Recording non-decisions
**Don't:** Create a decision for "Use standard naming conventions"
**Do:** Only record decisions with real trade-offs and rejected alternatives

### ❌ Duplicating product document content
**Don't:** Repeat everything in mission.md as decisions
**Do:** Decisions explain the *why behind* the choices in mission.md

### ❌ Vague decisions
**Don't:** "Decided to use a good architecture"
**Do:** "Use repository pattern for all data access (rejected active record due to testability concerns)"

### ❌ Over-generating
**Don't:** Create 20+ decisions from a simple project
**Do:** Be selective — only genuine decisions with real trade-offs and future impact
