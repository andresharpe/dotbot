---
name: Plan Internet Research
description: Create the internet research task via task_create
version: 1.0
---

# Plan Internet Research

This workflow creates a single internet research task that covers business context, regulatory requirements, alternative products/approaches, and technical documentation.

## Prerequisites

Before running this workflow:
- Phase 1 (product document) must be complete — `product.md` must exist

## Your Task

Create exactly 1 research task using `task_create`.

### Step 1: Read Project Context

```
Read({ file_path: ".bot/workspace/product/product.md" })
Read({ file_path: ".bot/workspace/product/interview-summary.md" })
```

Extract the project name and key goals for task naming.

### Step 2: Create Internet Research Task

```
mcp__dotbot__task_create({
  name: "Deep Internet Research for {PROJECT_NAME}",
  description: "Conduct comprehensive internet research covering business context, regulatory requirements, alternative products/approaches, and technical documentation for {PROJECT_NAME}.\n\nOutput: .bot/workspace/product/research-internet.md",
  category: "research",
  effort: "L",
  priority: 1,
  dependencies: [],
  research_prompt: "public.md",
  acceptance_criteria: [
    "research-internet.md written to .bot/workspace/product/",
    "Business context and market landscape documented",
    "Regulatory and compliance requirements researched",
    "Alternative products and approaches evaluated",
    "Technical documentation and patterns catalogued",
    "All sources cited with URLs"
  ],
  steps: [
    "Read product.md for project name and goals",
    "Load research methodology from recipes/research/public.md",
    "Research business context, regulatory landscape, and compliance requirements",
    "Identify alternative products, competing approaches, and industry benchmarks",
    "Gather technical documentation, API references, and integration patterns",
    "Write structured report to .bot/workspace/product/research-internet.md"
  ],
  applicable_standards: [".bot/recipes/standards/global/research-output.md"],
  applicable_agents: [".bot/recipes/agents/researcher/AGENT.md"]
})
```

### Step 3: Verify Creation

After `task_create` returns, verify:
1. Task created successfully (check `created_count == 1`)
2. Task has **no dependencies** (it runs independently)
3. Task has `category: "research"` and `research_prompt` field

Report the result to the user.

## Output

One research task in `.bot/workspace/tasks/todo/`:
1. Deep Internet Research (no dependencies, priority 1)

## Critical Rules

- Create exactly 1 task — no more, no fewer
- Use `task_create` — not `task_create_bulk`
- Include `research_prompt` field on the task
- Task has **no dependencies**
- Use the project name from `product.md` in the task name
- Do NOT execute the research — only create the task
