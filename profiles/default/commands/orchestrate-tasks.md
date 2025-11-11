# Orchestrate Tasks Command

Orchestrate the implementation of a spec across multiple task groups with structured prompts.

## Description

This command helps you coordinate implementation across multiple task groups from a specification. It:
- Creates an orchestration plan (orchestration.yml)
- Assigns standards to task groups
- Generates structured prompts for each task group
- Tracks progress across the spec

## When to Use

Use this command when you:
- Have a complete spec and tasks.md ready to implement
- Want to coordinate work across multiple task groups
- Need to manage which standards apply to which tasks
- Want structured orchestration of implementation
- Need clear, sequential implementation prompts

## Prerequisites

- Completed specification (spec.md)
- Task breakdown (tasks.md) with task groups
- Understanding of which agents/standards to use

## Multi-Phase Process

### Phase 1: Get tasks.md for This Spec

**IF** you already know which spec we're working on AND that spec folder has a `tasks.md` file:
- Use that and skip to Phase 2

**IF** you don't already know which spec OR it doesn't have a `tasks.md`:
- Display:
```
Please point me to a spec's `tasks.md` that you want to orchestrate implementation for.

If you don't have one yet, then run any of these commands first:
/shape-spec
/write-spec
/create-tasks
```

### Phase 2: Create orchestration.yml

Create `dotbot/specs/[spec-name]/orchestration.yml`

Populate with task groups from tasks.md:

```yaml
task_groups:
  - name: [task-group-1-name]
  - name: [task-group-2-name]
  - name: [task-group-3-name]
  # Repeat for each task group in tasks.md
```

### Phase 3: Assign Standards to Task Groups

Ask user to assign standards:

```
Please specify the standard(s) that should be used to guide the implementation of each task group:

1. [task-group-1-name]
2. [task-group-2-name]
3. [task-group-3-name]

For each task group number, you can specify any combination of the following:

"all" to include all of your standards
"global/*" to include all files inside standards/global
"frontend/components.md" to include specific standard file
"none" to include no standards for this task group
```

Update orchestration.yml with standards:

```yaml
task_groups:
  - name: authentication-system
    standards:
      - all
  - name: user-dashboard
    standards:
      - global/*
      - frontend/components.md
      - frontend/css.md
  - name: api-endpoints
    standards:
      - backend/*
      - global/error-handling.md
```

### Phase 4: Generate Implementation Prompts

Create prompt files in `dotbot/specs/[spec-name]/implementation/prompts/`

For each task group, create:
`[task-group-number]-[task-group-slug].md`

Example: `1-authentication-system.md`

**Prompt Template:**
```markdown
We're continuing our implementation of [spec-title] by implementing task group number [task-group-number]:

## Implement this task and its sub-tasks:

[Paste entire task group including parent task, all sub-tasks, and sub-bullet points]

## Understand the context

Read @dotbot/specs/[spec-name]/spec.md to understand the context for this spec and where the current task fits into it.

Also read these further context and references:
- @dotbot/specs/[spec-name]/planning/requirements.md (if exists)
- @dotbot/specs/[spec-name]/planning/visuals (if exists)

## Perform the implementation

Follow the workflow: @dotbot/workflows/implementation/implement-tasks.md

## User Standards & Preferences Compliance

IMPORTANT: Ensure that your implementation work is ALIGNED and DOES NOT CONFLICT with the user's preferences and standards as detailed in the following files:

[List compiled standards from orchestration.yml for this task group]
```

After creating all prompts, output:

```
Ready to begin implementation of [spec-title]!

Use the following list of prompts to direct the implementation of each task group:

1. dotbot/specs/[spec-name]/implementation/prompts/1-[task-1].md
2. dotbot/specs/[spec-name]/implementation/prompts/2-[task-2].md
3. dotbot/specs/[spec-name]/implementation/prompts/3-[task-3].md

Input those prompts into this chat one-by-one or queue them to run in order.

Progress will be tracked in `dotbot/specs/[spec-name]/tasks.md`
```

## Compiling Standards

When compiling standards for a task group from orchestration.yml:

1. If value is `"all"`: Include all standard files
2. If value is `"global/*"`: Include all files in standards/global/
3. If value is `"frontend/components.md"`: Include that specific file
4. Build a list of file paths to include

Output format for standards list:
```
- @dotbot/standards/global/coding-style.md
- @dotbot/standards/global/error-handling.md
- @dotbot/standards/frontend/components.md
```

## Output

- orchestration.yml with standards assignments
- Prompt files generated for each task group in `dotbot/specs/[spec-name]/implementation/prompts/`
- Clear implementation plan ready to execute sequentially in Warp

## Configuration Variables

This command adapts based on config.yml:
- `standards_as_warp_rules` - Whether standards are added to WARP.md as rules

## Example Usage

**User**: "Orchestrate the authentication spec"

**Agent**:
1. Reads authentication tasks.md
2. Creates orchestration.yml with 3 task groups
3. Asks which standards apply to each group
4. Generates prompt files for each task group
5. Provides sequential implementation plan

## Tips

- Review tasks.md before orchestrating
- Assign specialized agents to appropriate tasks
- Be specific about standards for each group
- Use "all" standards when unsure
- Track progress in tasks.md
- Update orchestration.yml as needed
- Coordinate dependencies between task groups
