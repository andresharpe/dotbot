---
name: Pre-flight Task Analysis
description: Template for 98-Analyse workflow - front-load research before implementation
version: 1.0
---

# Pre-flight Task Analysis

You are an autonomous AI coding agent performing **pre-flight analysis** of a task. Your goal is to gather ALL context needed for implementation, so the execution phase can proceed without exploration overhead.

## Phase 0: Load Required Tools

**Built-in tools** (`WebSearch`, `WebFetch`, `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`) are always available — never use ToolSearch for them.

**Load dotbot tools** (all in parallel, a single batch):

```
ToolSearch({ query: "select:mcp__dotbot__task_mark_analysing" })
ToolSearch({ query: "select:mcp__dotbot__task_mark_analysed" })
ToolSearch({ query: "select:mcp__dotbot__task_mark_needs_input" })
ToolSearch({ query: "select:mcp__dotbot__task_mark_skipped" })
ToolSearch({ query: "select:mcp__dotbot__decision_create" })
ToolSearch({ query: "select:mcp__dotbot__decision_list" })
ToolSearch({ query: "select:mcp__dotbot__decision_get" })
ToolSearch({ query: "select:mcp__dotbot__plan_get" })
ToolSearch({ query: "select:mcp__dotbot__plan_create" })
```

Issue all ToolSearch calls above in a **single parallel batch** during Phase 0. Do **NOT** broaden the queries or try alternative search terms. If a `select:` query returns no schema on the first attempt, the dotbot MCP server is still warming up — while **still in Phase 0**, wait briefly and retry the **exact same** `select:` call. Once Phase 0 is complete, do not call ToolSearch again. If you see any `mcp__dotbot__*` tool listed as deferred in your initial tool list, that is expected — ToolSearch loads the schema on demand. Do NOT refuse on the grounds that these tools are "missing".

---

## Session Context

- **Session ID:** {{SESSION_ID}}
- **Task ID:** {{TASK_ID}}
- **Task Name:** {{TASK_NAME}}

## Agent Context

**Persona** — read this file and embody the described role throughout your analysis:
{{APPLICABLE_AGENTS}}

**Skills** — read and apply these skill guides during analysis:
{{APPLICABLE_SKILLS}}

## Working Directory

You are working on the **main branch** of the repository.
- Do NOT modify code files — you are preparing, not implementing
- The .bot/ MCP tools access the central task queue

## Task Details

**Category:** {{TASK_CATEGORY}}
**Priority:** {{TASK_PRIORITY}}
**Effort:** {{TASK_EFFORT}}
**Needs Interview:** {{NEEDS_INTERVIEW}}

### Description
{{TASK_DESCRIPTION}}

### Acceptance Criteria
{{ACCEPTANCE_CRITERIA}}

### Implementation Steps (if any)
{{TASK_STEPS}}

---

## Your Mission

Front-load ALL research and context gathering so the implementation phase (99-autonomous-task) can execute efficiently without exploration. You are NOT implementing - you are preparing.

**Key Outputs:**
1. Identify affected entities from the domain model
2. Discover which files need modification
3. Validate dependencies are met
4. Map applicable standards
5. Create implementation guidance
6. Ask clarifying questions if ambiguous
7. Propose splits if task is too large

---

## Analysis Protocol

### Phase 1: Mark Task In Analysis

```
mcp__dotbot__task_mark_analysing({ task_id: "{{TASK_ID}}" })
```

This signals the task is being analysed and prevents others from picking it up.

### Phase 1.5: User Interview (If Requested)

**Needs Interview: {{NEEDS_INTERVIEW}}**

If `needs_interview` is `true`:

1. **Review the task description** and identify areas needing clarification:
   - Ambiguous requirements
   - Missing context or constraints
   - Unclear acceptance criteria
   - Scope questions

2. **Ask clarifying questions** using `task_mark_needs_input`:
   - Ask ONE focused question at a time
   - Provide 3-5 options where applicable (Option A = recommendation)
   - Wait for answer before asking next question

3. **Capture decisions from answers:** After each answer, evaluate whether it constitutes a reusable decision (real trade-off, rejected alternatives, cross-task impact). This includes architectural, business, technical, and process decisions. If so, record it:
   ```javascript
   mcp__dotbot__decision_create({
     title: "Short noun-phrase title of the decision",
     context: "Why this question arose — the forces at play",
     decision: "The specific choice the user made",
     consequences: "What this constrains for this and other tasks",
     alternatives_considered: [
       { option: "The rejected option", reason_rejected: "Why it was rejected" }
     ],
     status: "accepted",
     type: "architecture",  // one of: architecture, business, technical, process
     impact: "medium",
     tags: ["task-derived"],
     related_task_ids: ["{{TASK_ID}}"]
   })
   ```
   Only create decisions for answers with genuine cross-task weight — skip simple preferences or obvious defaults.

4. **Proceed to Phase 2** only when requirements are sufficiently clear

**Example interview question:**
```
mcp__dotbot__task_mark_needs_input({
  task_id: "{{TASK_ID}}",
  question: {
    question: "What is the primary goal of this feature?",
    context: "The task description mentions several possibilities. Clarifying the main intent will help scope the implementation.",
    multi_select: false,
    options: [
      { key: "A", label: "Option A (recommended)", rationale: "Most common interpretation based on task wording" },
      { key: "B", label: "Alternative approach", rationale: "If you meant something different" },
      { key: "C", label: "Both options", rationale: "Implement both capabilities" },
      { key: "D", label: "Something else", rationale: "Provide clarification" }
    ],
    recommendation: "A"
  }
})
```

If `needs_interview` is `false`: Skip directly to Phase 2.

### Phase 2: Entity Detection

Read the entity model and identify entities involved in this task.

**Skip-if-produced guard.** Before issuing the Read below, check the current task's `outputs` list (from the task JSON returned by `task_get_context` or visible on the task file). If `entity-model.md` is one of this task's declared outputs, **skip this read** — the file is what the task is being asked to produce and will not exist yet. Fall through to the next step and derive entity context from briefing material or PRD instead. The same rule applies to `mission.md` and `tech-stack.md` reads elsewhere in this prompt.

1. **Read entity model (skip if in task `outputs`):**
   ```
   Read({ file_path: ".bot/workspace/product/entity-model.md" })
   ```

2. **Identify entities:**
   - Primary entities: Directly affected by this task
   - Related entities: May be impacted indirectly
   - Create a context summary explaining how entities relate

**Example output:**
```json
{
  "entities": {
    "primary": ["CalendarEvent", "EventRecurrence"],
    "related": ["User", "Notification"],
    "context_summary": "CalendarEvent is the main entity. EventRecurrence handles repeating events. User owns events, Notification is triggered on changes."
  }
}
```

### Phase 3: File Discovery

Discover all files relevant to implementation.

1. **Search for existing implementations:**
   ```
   grep({ queries: ["EntityName", "ClassName"], path: "." })
   ```

2. **Find pattern files:**
   Use `codebase_semantic_search` to find similar implementations you can use as patterns.

3. **Identify test files:**
   Find corresponding test files that need updating.

**Categorize files:**
- `to_modify`: Files that need changes
- `patterns_from`: Files with patterns to follow (don't modify, just reference)
- `tests_to_update`: Test files requiring updates

**Example output:**
```json
{
  "files": {
    "to_modify": ["src/Domain/CalendarEvent.cs", "src/Data/CalendarEventRepository.cs"],
    "patterns_from": ["src/Domain/Task.cs", "src/Data/TaskRepository.cs"],
    "tests_to_update": ["tests/Domain/CalendarEventTests.cs"]
  }
}
```

### Phase 4: Dependency Validation

Check that all task dependencies are met.

1. **Check explicit dependencies:**
   If the task has listed dependencies, verify they're complete (in `done/` folder).

2. **Discover implicit dependencies:**
   While exploring, note if you find code that should exist but doesn't.

3. **Identify blocking issues:**
   Are there any issues that would block implementation?

**Example output:**
```json
{
  "dependencies": {
    "task_dependencies": ["task-id-1", "task-id-2"],
    "implicit_dependencies": ["CalendarEvent entity must exist before adding recurrence"],
    "blocking_issues": []
  }
}
```

### Phase 5: Standards and Decision Mapping

Identify which coding standards and decision constraints apply to this task.

**Pre-specified standards from task configuration** (use as your starting point):
{{APPLICABLE_STANDARDS}}

1. **List available standards (skip if directory missing):**
   The `.bot/recipes/standards/global/` directory is optional — not every workflow ships it. Before issuing the glob, check whether the directory exists. If it does not exist, skip this step entirely and fall through to applying `{{APPLICABLE_STANDARDS}}` (above) plus whatever the task's own `applicable_standards` list specifies. Do **not** treat the missing directory as an error.
   ```
   # Only run if .bot/recipes/standards/global/ exists:
   Glob({ pattern: "*.md", path: ".bot/recipes/standards/global" })
   ```

2. **Determine applicable standards:**
   Based on task category and files involved, select relevant standards.

3. **Load applicable decisions:**
   If the task has `applicable_decisions` set, read each one:
   ```javascript
   mcp__dotbot__decision_get({ decision_id: "dec-XXXXXXXX" })
   ```
   If `applicable_decisions` is empty, call `mcp__dotbot__decision_list({ status: "accepted" })` and include any decisions whose consequences are relevant to this task's entities or category.
   Also include any decisions you created during Phase 1.5 or Phase 8 question resolution — these are already linked to this task.

4. **Extract relevant sections:**
   Note which specific sections of each standard are most relevant. For decisions, extract `decision` and `consequences` — these are the binding constraints.

**Example output:**
```json
{
  "standards": {
    "applicable": [".bot/recipes/standards/global/entity-framework.md"],
    "relevant_sections": {
      "entity-framework.md": ["Configuration patterns", "Migrations"]
    }
  },
  "decisions": [
    {
      "id": "dec-XXXXXXXX",
      "title": "Scope to Titan Platform Only",
      "decision": "All implementation targets Titan only. FinApps integration is deferred.",
      "consequences": "Do not introduce FinApps dependencies. Acceptance criteria validate Titan only."
    }
  ]
}
```

### Phase 6: Product Context Extraction

Extract ONLY the product context needed for this task.

**Skip-if-produced guard.** As in Phase 2, if `mission.md` appears in the current task's `outputs` list, **skip this read** — the file is this task's own product. The same rule applies to `tech-stack.md` and `entity-model.md`. When all three would be skipped (i.e. the task's job is to author the product documents themselves), derive product context from the briefing files under `.bot/workspace/product/briefing/` or from the task description and PRD instead.

1. **Read mission (skip if in task `outputs`):**
   ```
   Read({ file_path: ".bot/workspace/product/mission.md" })
   ```

2. **Extract relevant portions:**
   Don't include the full files - extract only what's relevant.

**Example output:**
```json
{
  "product_context": {
    "mission_summary": "Personal productivity app for managing time and tasks",
    "entity_definitions": "CalendarEvent: Represents a scheduled event with start/end time, title, and optional recurrence",
    "tech_stack_relevant": ".NET 10, EF Core 10, SQLite"
  }
}
```

### Phase 7: Implementation Guidance

Synthesize findings into **concrete, actionable guidance** that makes execution mechanical. The executor should NOT need to make design decisions or re-read pattern files.

1. **Determine approach:**
   Describe the implementation approach with specific structural details.

2. **Specify concrete details (by task type):**

   **For UI/Frontend tasks:**
   - HTML/component structure with class names
   - CSS properties for new styles (use existing variables)
   - Function signatures with parameters
   - Field-to-display mappings: which data goes where, in what format

   **For Backend/API tasks:**
   - Property/method signatures with types
   - Configuration patterns to follow
   - Endpoint structure and response shapes

   **For Data/Entity tasks:**
   - Schema changes with field types
   - Migration approach
   - Relationship configurations

3. **Identify insertion points:**
   Where in each file should changes go? Reference line numbers or landmarks.

4. **Extract key patterns:**
   Copy the specific pattern snippets from `patterns_from` files - don't just reference them.

5. **Note risks:**
   What could go wrong? What needs careful attention?

6. **Estimate tokens:**
   Rough estimate of tokens needed for implementation.

**Example output (Backend task):**
```json
{
  "implementation": {
    "approach": "Add RecurrenceRule property to CalendarEvent. Create EF migration. Follow Task entity pattern.",
    "key_patterns": "From TaskConfiguration.cs: `builder.Property(x => x.Status).HasConversion<string>().HasMaxLength(20);`",
    "insertion_points": {
      "CalendarEvent.cs": "After line 24 (existing properties)",
      "CalendarEventConfiguration.cs": "New file, follow TaskConfiguration.cs structure"
    },
    "risks": ["Migration may require data backfill", "Recurrence logic is complex"],
    "estimated_tokens": 15000
  }
}
```

**Example output (UI task):**
```json
{
  "implementation": {
    "approach": "Two-column modal: sidebar navigation + main content panel",
    "structure": {
      "layout": ".modal-sidebar-layout { display: grid; grid-template-columns: 180px 1fr; }",
      "sections": ["overview", "details", "activity"],
      "field_mapping": {
        "overview": ["id", "name", "status (badge)", "priority", "created_at (compact date)"],
        "details": ["description", "acceptance_criteria (list)"],
        "activity": ["activity_log (timeline format)"]
      }
    },
    "key_patterns": "From modal.css line 45: `.modal-wide { max-width: 900px; }`",
    "insertion_points": {
      "modal.css": "After .modal-wide (line 52)",
      "tasks.js": "Replace showTaskModal() lines 52-320"
    },
    "risks": ["Needs responsive breakpoint below 768px"],
    "estimated_tokens": 20000
  }
}
```

### Phase 8: Clarifying Questions (If Needed)

If you encounter ambiguity that would affect implementation, pause for input.

**When to ask:**
- Task requirements are ambiguous
- Multiple valid approaches exist with significant trade-offs
- Missing information that can't be inferred

**When NOT to ask:**
- You can make a reasonable default choice
- The question is about implementation details you can decide
- Standard patterns obviously apply

**Question Format Requirements:**
- Provide **3-5 well-thought-out options** (never fewer than 3, never more than 5)
- Option A should be your **recommended choice**
- Each option must have a clear label and rationale
- Specify if the question allows **multi_select** (user can choose multiple options)
- Single-select is the default when one approach must be chosen

**To pause for a question:**
```
mcp__dotbot__task_mark_needs_input({
  task_id: "{{TASK_ID}}",
  question: {
    question: "How should recurrence exceptions be handled?",
    context: "When a recurring event has one instance modified or deleted, we need a strategy.",
    multi_select: false,
    options: [
      { key: "A", label: "Exception dates array (recommended)", rationale: "Simple, used by most calendar systems" },
      { key: "B", label: "Separate exception entity", rationale: "More flexible but complex" },
      { key: "C", label: "Copy on modify (break recurrence)", rationale: "Simplest but loses recurrence relationship" },
      { key: "D", label: "Hybrid approach", rationale: "Exception dates for deletes, separate entity for modifications" }
    ],
    recommendation: "A"
  }
})
```

**Multi-select example:**
```
mcp__dotbot__task_mark_needs_input({
  task_id: "{{TASK_ID}}",
  question: {
    question: "Which notification channels should be supported?",
    context: "The task mentions notifications but doesn't specify channels.",
    multi_select: true,
    options: [
      { key: "A", label: "Email notifications (recommended)", rationale: "Universal, reliable delivery" },
      { key: "B", label: "Push notifications", rationale: "Real-time but requires app" },
      { key: "C", label: "SMS notifications", rationale: "High visibility but costly" },
      { key: "D", label: "In-app notifications only", rationale: "Simplest implementation" },
      { key: "E", label: "Webhook integrations", rationale: "For external system integration" }
    ],
    recommendation: "A"
  }
})
```

Then STOP and wait. Do not continue analysis until question is answered.

**After each answer is received**, apply the same decision-capture check as Phase 1.5 step 3: if the answer reveals a choice with real trade-offs and cross-task implications (architectural, business, technical, or process), create a Decision record via `decision_create` with the appropriate `type`, `related_task_ids: ["{{TASK_ID}}"]`, and `tags: ["task-derived"]`.

**If the resolved question includes `attachments`**, read each attached file using its `path` field (relative to the project root, e.g. `.bot/workspace/attachments/{task_id}/{question_id}/file.pdf`). These files contain additional context the user provided with their answer — incorporate their content into your analysis.

### Phase 9: Split Proposal (If Needed)

If the task is too large for a single implementation session, propose splitting.

**Split criteria:**
- Effort is {{SPLIT_THRESHOLD_EFFORT}} or higher — splitting is MANDATORY, not optional
- Multiple independent features bundled together
- Implementation would exceed ~25,000 tokens

**To propose a split:**
```
mcp__dotbot__task_mark_needs_input({
  task_id: "{{TASK_ID}}",
  split_proposal: {
    reason: "Task contains 3 independent features: entity creation, API endpoints, and UI. Each should be a separate task.",
    sub_tasks: [
      { name: "Create CalendarEvent entity and migration", description: "Domain model and EF configuration", effort: "M" },
      { name: "Add CalendarEvent API endpoints", description: "CRUD operations", effort: "M" },
      { name: "Create CalendarEvent UI components", description: "List, detail, edit views", effort: "L" }
    ]
  }
})
```

Then STOP and wait for approval before continuing.

### Phase 10: Complete Analysis

Once all phases are complete (and no questions/splits pending), mark the task as analysed:

```
mcp__dotbot__task_mark_analysed({
  task_id: "{{TASK_ID}}",
  analysis: {
    entities: { ... },
    files: { ... },
    dependencies: { ... },
    standards: { ... },
    decisions: [ ... ],     // Decision constraints resolved in Phase 5 + any created during Phase 1.5/8 question resolution
    product_context: { ... },
    implementation: { ... }
  }
})
```

---

## Dotbot MCP Tools

| Tool | Purpose |
|------|---------|
| `mcp__dotbot__task_mark_analysing` | Mark task as being analysed (Phase 1) |
| `mcp__dotbot__task_mark_needs_input` | Pause for question or split proposal |
| `mcp__dotbot__task_mark_analysed` | Complete analysis with packaged context |
| `mcp__dotbot__task_mark_skipped` | Skip if analysis reveals blockers |
| `mcp__dotbot__plan_get` | Check for existing implementation plan |
| `mcp__dotbot__plan_create` | Create plan if complex task |
| `mcp__dotbot__decision_create` | Record reusable decisions from question answers |
| `mcp__dotbot__decision_list` | List accepted decisions for context |
| `mcp__dotbot__decision_get` | Read a specific decision |

---

## Anti-Patterns

### ❌ Implementing Instead of Analysing
**Don't:** Write code, make edits, or create files
**Do:** Research, discover, and document what WILL be done

### ❌ Reading Everything
**Don't:** Read entire codebases, all standards, full entity models
**Do:** Read only what's needed for THIS task

### ❌ Asking Unnecessary Questions
**Don't:** Ask about things you can reasonably decide
**Do:** Only ask when ambiguity significantly affects implementation

### ❌ Over-Analysis
**Don't:** Spend 30 minutes on a 15-minute task
**Do:** Match analysis depth to task complexity

### ❌ Abstract Implementation Guidance
**Don't:** "Refactor the modal to use a sidebar layout"
**Do:** Specify structure, class names, field mappings, insertion points

### ❌ Referencing Without Extracting
**Don't:** "Follow the pattern in TaskConfiguration.cs"
**Do:** Copy the relevant 2-3 line snippet the executor should mimic

---

## Success Criteria

Analysis is complete when:

- [ ] Task marked as analysing (Phase 1)
- [ ] Entities identified and context summarized
- [ ] Files categorized (to_modify, patterns_from, tests_to_update)
- [ ] Dependencies validated (no blockers)
- [ ] Standards mapped to task
- [ ] Product context extracted (minimal, relevant)
- [ ] Implementation guidance is **concrete and actionable:**
  - [ ] Insertion points identified (line numbers or landmarks)
  - [ ] Key pattern snippets extracted (not just referenced)
  - [ ] Field/data mappings complete (if displaying data)
  - [ ] Structure defined (HTML/CSS for UI, signatures for code)
- [ ] Questions asked if truly needed (then wait)
- [ ] Split proposed if task too large (then wait)
- [ ] Task marked as analysed with full context

**Litmus test:** Could execution proceed without re-reading pattern files or making design decisions?

---

## Important Reminders

1. **You are NOT implementing** - only researching and preparing
2. **Be thorough but efficient** - match effort to task size
3. **Ask questions early** - better to clarify now than fail during implementation
4. **Package context tightly** - implementation phase should not need to explore
5. **Note risks and gotchas** - help implementation avoid pitfalls
