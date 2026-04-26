---
name: Expand Task Group
description: Expand a single gap-analysis task group into detailed tasks via task_create_bulk
version: 1.0
---

# Expand Gap Analysis Group: {{GROUP_NAME}}

You are a task planning assistant. Your job is to create detailed, implementable tasks for ONE specific gap-analysis group.

## Your Group

- **Group ID:** {{GROUP_ID}}
- **Name:** {{GROUP_NAME}}
- **Description:** {{GROUP_DESCRIPTION}}
- **Category Hint:** {{CATEGORY_HINT}}
- **Priority Range:** {{PRIORITY_MIN}} to {{PRIORITY_MAX}}
- **Applicable Decisions:** {{GROUP_APPLICABLE_DECISIONS}}

### Scope Items

{{GROUP_SCOPE}}

### Acceptance Criteria

{{GROUP_ACCEPTANCE_CRITERIA}}

## Context from Prerequisite Groups

The following tasks were created by groups that this group depends on. You MUST analyze these tasks and set `dependencies` on any task that cannot start without a specific prerequisite completing first.

{{DEPENDENCY_TASKS}}

**Dependency guidance:** Add cross-group dependencies where there is a real technical dependency. Do NOT add dependencies just because groups are ordered — priority ranges already encode execution order.

## Instructions

### Step 1: Read Product Documents and Context

Read these files for project context:
- `.bot/workspace/product/mission.md` — Core principles and goals
- `.bot/workspace/product/tech-stack.md` — Technology stack and libraries
- `.bot/workspace/product/entity-model.md` — Data model and relationships
- `.bot/workspace/product/briefing/repo-scan.md` — Detailed codebase structure
- Any other `.md` files in `.bot/workspace/product/` for additional context

If `{{GROUP_APPLICABLE_DECISIONS}}` is non-empty, read each decision:
```javascript
mcp__dotbot__decision_get({ decision_id: "dec-XXXXXXXX" })
```

### Step 2: Break Down Scope Items into Tasks

For each scope item listed above, create 1-3 detailed tasks. Each task should be:

- **Completable in 1-4 hours** of focused work
- **Independently testable** where possible
- **Small enough** to fit in a single LLM context window
- **Specific to the gap being addressed** — reference actual files, directories, and patterns from the repo scan

**Task sizing guide:**

| Effort | Duration | Examples |
|--------|----------|----------|
| XS | < 1 hour | Add missing test for single function, fix one deprecated API call |
| S | 1-2 hours | Add test suite for one module, update one outdated dependency |
| M | 2-4 hours | Add integration tests for an API flow, document an entire module |
| L | 4-8 hours | Set up test infrastructure from scratch, add CI pipeline |
| XL | 1-2 days | Major refactor of tech debt area (consider splitting further) |

### Step 2.5: Identify Dependencies

Before creating tasks, analyze which tasks depend on others:

1. **Intra-group dependencies** — Tasks within this group that must execute in order. When you create tasks via `task_create_bulk`, earlier tasks in the batch can be referenced by name in later tasks' `dependencies` array.

2. **Cross-group dependencies** — Check `{{DEPENDENCY_TASKS}}` above. If any task requires output from a prerequisite group's task, add that task's ID to `dependencies`.

### Step 3: Create Tasks via MCP

Use `task_create_bulk` to create all tasks for this group:

```javascript
task_create_bulk({
  tasks: [
    {
      name: "Action-oriented task title",
      description: "What gap this addresses, where in the codebase, why it matters, specific files/patterns to modify",
      category: "{{CATEGORY_HINT}}",
      priority: /* within {{PRIORITY_MIN}}-{{PRIORITY_MAX}} */,
      effort: "M",
      group_id: "{{GROUP_ID}}",
      acceptance_criteria: [
        "Specific testable criterion",
        "Measurable improvement"
      ],
      steps: [
        "Concrete implementation step referencing actual files",
        "Verification step"
      ],
      dependencies: [],
      applicable_standards: [],
      applicable_agents: [],
      applicable_decisions: [],
      human_hours: 4,
      ai_hours: 1
    }
  ]
})
```

### Important Rules

1. **Stay within scope.** Only create tasks for THIS group's scope items.
2. **Use the assigned priority range.** All tasks must have priorities between {{PRIORITY_MIN}} and {{PRIORITY_MAX}}.
3. **Set `group_id`** to `"{{GROUP_ID}}"` on every task.
4. **Be specific to THIS project.** Reference actual file paths, module names, and patterns from the repo scan. Generic tasks like "improve test coverage" are not acceptable.
5. **Do NOT ask questions.** Work autonomously with the information available.
6. **Do NOT create a roadmap overview.** That is handled separately.
7. **Set `dependencies`** for any task that requires output from another task.
8. **Do NOT execute code, run tests, run builds, or invoke shell commands.** You are writing task *definitions* that describe work to be done later — you are not verifying, reproducing, or implementing anything. Scope items phrased as "fix failing tests", "update dependencies", or "resolve issues" mean *create tasks that describe the fix*; they do not authorise you to run `dotnet test`, `npm test`, `pytest`, builds, installers, or any other shell command. The `Bash` tool is OFF-LIMITS in this phase. Any empirical verification is the job of the task executor that picks up these tasks later.
9. **Do NOT re-scan the live codebase.** Work from the already-generated briefings (`repo-scan.md`, `git-history.md`) plus targeted `Read`s on specific files named in scope items. Do not use `Glob` or `Grep` to go hunting for new files, and do not spawn sub-`Agent`s that re-explore the repo — the briefings already contain everything you need. If a scope item references a file you need details on, `Read` that one file and move on.

### Task Writing Guidelines

**Good task names for gap analysis:**
- "Add unit tests for {ModuleName} service"
- "Update {dependency} from v{old} to v{new}"
- "Document API endpoints in {path}"
- "Add input validation to {endpoint}"
- "Set up CI pipeline for automated testing"

**Good descriptions include:**
- **What gap**: Which specific gap this addresses
- **Where**: File paths and modules affected
- **Why**: Impact of not addressing this gap
- **How**: Specific approach based on project patterns

## Output

After creating all tasks, report:
- Number of tasks created
- Task names and their priorities
- Any cross-group dependencies added (with justification)
