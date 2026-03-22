---
name: Plan Sourcebot Research
description: Create the Sourcebot research task via task_create
version: 1.0
---

# Plan Sourcebot Research

This workflow creates a single Sourcebot research task that discovers all repositories relevant to the initiative, classifies them by relevance and impact, and maps cross-repo dependencies.

## Prerequisites

Before running this workflow:
- Phase 0 (kickstart) must be complete — `briefing/jira-context.md` must exist
- Phase 1 (plan product) must be complete — `mission.md` and `roadmap-overview.md` must exist

## Your Task

Create exactly 1 research task using `task_create`.

### Step 1: Read Initiative Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
```

Extract the initiative name and Jira key for task naming.

### Step 2: Create Sourcebot Research Task

```
mcp__dotbot__task_create({
  name: "Deep Sourcebot Research for {INITIATIVE_NAME}",
  description: "Use Sourcebot MCP tools to discover all repositories relevant to {JIRA_KEY}. Classify repos by relevance and impact. Map cross-repo dependencies.\n\nOutput: .bot/workspace/product/research-repos.md",
  category: "research",
  effort: "XL",
  priority: 1,
  dependencies: [],
  research_prompt: "repos.md",
  acceptance_criteria: [
    "research-repos.md written to .bot/workspace/product/",
    "All relevant repos identified using Sourcebot search",
    "Repos classified by tier (1-6) and impact (HIGH/MEDIUM/LOW)",
    "Cross-repo dependencies mapped",
    "Reference implementation pattern identified",
    "Each repo entry includes: name, project, relevance rationale, impact level"
  ],
  steps: [
    "Read jira-context.md for context and search terms",
    "Load research methodology from prompts/research/repos.md",
    "Use Sourcebot MCP tools to search for code patterns related to the initiative",
    "Discover repos by searching for domain entities, configuration keys, API patterns",
    "Classify repos by tier (1-6) and impact level (HIGH/MEDIUM/LOW)",
    "Map cross-repo dependencies and integration points",
    "Identify reference implementation",
    "Write structured report to .bot/workspace/product/research-repos.md"
  ],
  applicable_standards: [".bot/prompts/standards/global/research-output.md"],
  applicable_agents: [".bot/prompts/agents/researcher/AGENT.md"]
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
1. Deep Sourcebot Research (no dependencies, priority 1)

## Critical Rules

- Create exactly 1 task — no more, no fewer
- Use `task_create` — not `task_create_bulk`
- Include `research_prompt` field on the task
- Task has **no dependencies**
- Use the initiative name and Jira key from `jira-context.md` in the task name
- Do NOT execute the research — only create the task
