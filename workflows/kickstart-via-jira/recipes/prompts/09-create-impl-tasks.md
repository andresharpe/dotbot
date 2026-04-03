---
name: Create Implementation Tasks
description: Create per-repo implementation tasks via task_create_bulk
version: 1.0
---

# Create Implementation Tasks

This workflow creates implementation tasks for each affected repository. Tasks are created but NOT executed — execution happens in the next phase.

## Prerequisites

- Implementation plans must exist: `repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md`
- Repos must be cloned to `repos/{RepoName}/` with initiative branch checked out
- `jira-context.md` must exist
- `04_IMPLEMENTATION_RESEARCH.md` should exist for cross-repo context

## Your Task

### Step 1: Read Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/briefing/04_IMPLEMENTATION_RESEARCH.md" })
```

Check repo status:
```
mcp__dotbot__repo_list({})
```

### Step 2: Determine Implementation Order

Read the dependency map if it exists:
```
Read({ file_path: ".bot/workspace/product/briefing/05_DEPENDENCY_MAP.md" })
```

Follow the recommended implementation sequence. If no dependency map exists, implement in tier order (Tier 1 first).

### Step 3: Create Per-Repo Implementation Tasks

For each repo with a plan, create implementation tasks via `task_create_bulk`:

```
mcp__dotbot__task_create_bulk({
  tasks: [
    {
      "name": "Implement changes in {RepoName}",
      "description": "Execute the implementation plan for {RepoName}. Follow {RepoName}_Plan.md. Commit all changes to the initiative branch.\n\nPlan: repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md\nOutput: repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md",
      "category": "implementation",
      "effort": "{FROM_PLAN}",
      "priority": "{BASED_ON_IMPLEMENTATION_ORDER}",
      "dependencies": ["{UPSTREAM_REPO_TASKS}"],
      "working_dir": "repos/{RepoName}",
      "acceptance_criteria": [
        "All planned file changes implemented",
        "All planned new files created",
        "Configuration entries added",
        "Database scripts created (if applicable)",
        "Unit tests written and passing",
        "Changes committed to initiative branch",
        "Outcomes document produced"
      ],
      "steps": [
        "Read {RepoName}_Plan.md for detailed implementation instructions",
        "Implement changes in order specified by the plan",
        "Follow code patterns from reference implementation",
        "Add configuration entries",
        "Create database scripts (if applicable)",
        "Write unit tests",
        "Run build and test commands from the plan",
        "Commit all changes to initiative branch",
        "Write {RepoName}_Outcomes.md using outcomes template"
      ],
      "applicable_standards": [],
      "applicable_agents": [".bot/recipes/agents/implementer/AGENT.md"]
    }
  ]
})
```

### Step 4: Verify Creation

After `task_create_bulk` returns, verify:
1. All tasks created successfully (check `created_count` matches number of repos with plans)
2. Tasks have correct `category: "implementation"` and `working_dir` fields
3. Dependencies between repos are correctly set based on the dependency map

Report the result to the user.

## Output

Implementation tasks in `.bot/workspace/tasks/todo/`:
- One task per repo with an implementation plan
- Tasks ordered by dependency map / tier order
- Each task references its `{RepoName}_Plan.md`

## Critical Rules

- Create one task per repo that has an implementation plan — no more, no fewer
- Use `task_create_bulk` — not individual `task_create` calls
- Include `working_dir` field on each task pointing to the repo directory
- Respect cross-repo implementation order from dependency map
- Use the initiative name and Jira key from `jira-context.md` in task names
- Do NOT execute the implementation — only create the tasks
