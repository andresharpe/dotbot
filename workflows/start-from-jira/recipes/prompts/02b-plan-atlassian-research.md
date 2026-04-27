---
name: Plan Atlassian Research
description: Create the Atlassian research task via task_create
version: 1.0
---

> **TASK GENERATION ONLY.** This phase creates a task definition. Do NOT execute any research, download files, or edit product documents. Call `task_create` and stop.

# Plan Atlassian Research

This workflow creates a single Atlassian research task that downloads all relevant Jira/Confluence attachments and produces a document index with content summaries and relevance scores.

## Prerequisites

Before running this workflow:
- Phase 0 must be complete — `briefing/jira-context.md` must exist
- Phase 1 (plan product) must be complete — `mission.md` and `roadmap-overview.md` must exist

## Your Task

Create exactly 1 research task using `task_create`.

### Step 1: Read Initiative Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
```

Extract the initiative name and Jira key for task naming.

### Step 2: Create Atlassian Research Task

```
mcp__dotbot__task_create({
  name: "Deep Atlassian Research for {INITIATIVE_NAME}",
  description: "Download all relevant Atlassian attachments and Confluence documents for {JIRA_KEY}. Produce a document index with content summaries and relevance scores.\n\nDownloads: briefing/docs/ (via atlassian_download tool)\nOutput: .bot/workspace/product/research-documents.md",
  category: "research",
  effort: "L",
  priority: 1,
  dependencies: [],
  research_prompt: "atlassian.md",
  acceptance_criteria: [
    "All Jira attachments downloaded to briefing/docs/",
    "All relevant Confluence attachments downloaded to briefing/docs/",
    "research-documents.md written to .bot/workspace/product/",
    "Document index table with: relative path, content summary, relevance score (1-10)",
    "Cross-source contradictions flagged",
    "Key findings extracted from each document"
  ],
  steps: [
    "Read jira-context.md for Jira key, initiative name, and context",
    "Load research methodology from recipes/research/atlassian.md",
    "Call atlassian_download tool to download all attachments",
    "Read and summarise each downloaded document",
    "Scan Jira comments and status history for additional context",
    "Scan Confluence pages for related documentation",
    "Write document index to .bot/workspace/product/research-documents.md"
  ],
  applicable_standards: [".bot/recipes/standards/global/research-output.md"],
  applicable_agents: [".bot/workflows/start-from-jira/recipes/agents/researcher/AGENT.md"]
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
1. Deep Atlassian Research (no dependencies, priority 1)

## Critical Rules

- Create exactly 1 task — no more, no fewer
- Use `task_create` — not `task_create_bulk`
- Include `research_prompt` field on the task
- Task has **no dependencies**
- Use the initiative name and Jira key from `jira-context.md` in the task name
- Do NOT execute the research — only create the task
