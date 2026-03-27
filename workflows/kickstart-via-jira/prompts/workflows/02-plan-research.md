---
name: Plan Research
description: Create the 3 foundational research tasks via task_create_bulk
version: 2.0
---

# Plan Research

This workflow creates the initial research tasks that form the foundation of the multi-repo initiative lifecycle. All 3 tasks run in parallel (no inter-dependencies) and produce structured output to specific paths.

## Prerequisites

Before running this workflow:
- Phase 0 (kickstart) must be complete — `briefing/jira-context.md` must exist
- Phase 0.5 (plan product) must be complete — `mission.md` and `roadmap-overview.md` must exist

## Your Task

Create exactly 3 research tasks using `task_create_bulk`. These tasks cover the three foundational research streams — all run in **parallel** with no dependencies between them.

### Step 1: Read Initiative Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
```

Extract the initiative name and Jira key for task naming.

### Step 2: Create Research Tasks

```
mcp__dotbot__task_create_bulk({
  tasks: [
    {
      "name": "Deep Internet Research for {INITIATIVE_NAME}",
      "description": "Conduct comprehensive internet research covering business context, regulatory requirements, alternative products/approaches, and technical documentation for {INITIATIVE_NAME}.\n\nOutput: .bot/workspace/product/research-internet.md",
      "category": "research",
      "effort": "L",
      "priority": 1,
      "dependencies": [],
      "research_prompt": "public.md",
      "acceptance_criteria": [
        "research-internet.md written to .bot/workspace/product/",
        "Business context and market landscape documented",
        "Regulatory and compliance requirements researched",
        "Alternative products and approaches evaluated",
        "Technical documentation and patterns catalogued",
        "All sources cited with URLs"
      ],
      "steps": [
        "Read jira-context.md for initiative name and business objective",
        "Load research methodology from prompts/research/public.md",
        "Research business context, regulatory landscape, and compliance requirements",
        "Identify alternative products, competing approaches, and industry benchmarks",
        "Gather technical documentation, API references, and integration patterns",
        "Write structured report to .bot/workspace/product/research-internet.md"
      ],
      "applicable_standards": [".bot/prompts/standards/global/research-output.md"],
      "applicable_agents": [".bot/workflows/kickstart-via-jira/prompts/agents/researcher/AGENT.md"]
    },
    {
      "name": "Deep Atlassian Research for {INITIATIVE_NAME}",
      "description": "Download all relevant Atlassian attachments and Confluence documents for {JIRA_KEY}. Produce a document index with content summaries and relevance scores.\n\nDownloads: briefing/docs/ (via atlassian_download tool)\nOutput: .bot/workspace/product/research-documents.md",
      "category": "research",
      "effort": "L",
      "priority": 1,
      "dependencies": [],
      "research_prompt": "atlassian.md",
      "acceptance_criteria": [
        "All Jira attachments downloaded to briefing/docs/",
        "All relevant Confluence attachments downloaded to briefing/docs/",
        "research-documents.md written to .bot/workspace/product/",
        "Document index table with: relative path, content summary, relevance score (1-10)",
        "Cross-source contradictions flagged",
        "Key findings extracted from each document"
      ],
      "steps": [
        "Read jira-context.md for Jira key, initiative name, and context",
        "Load research methodology from prompts/research/atlassian.md",
        "Call atlassian_download tool to download all attachments",
        "Read and summarise each downloaded document",
        "Scan Jira comments and status history for additional context",
        "Scan Confluence pages for related documentation",
        "Write document index to .bot/workspace/product/research-documents.md"
      ],
      "applicable_standards": [".bot/prompts/standards/global/research-output.md"],
      "applicable_agents": [".bot/workflows/kickstart-via-jira/prompts/agents/researcher/AGENT.md"]
    },
    {
      "name": "Deep Sourcebot Research for {INITIATIVE_NAME}",
      "description": "Use Sourcebot MCP tools to discover all repositories relevant to {JIRA_KEY}. Classify repos by relevance and impact. Map cross-repo dependencies.\n\nOutput: .bot/workspace/product/research-repos.md",
      "category": "research",
      "effort": "XL",
      "priority": 1,
      "dependencies": [],
      "research_prompt": "repos.md",
      "acceptance_criteria": [
        "research-repos.md written to .bot/workspace/product/",
        "All relevant repos identified using Sourcebot search",
        "Repos classified by tier (1-6) and impact (HIGH/MEDIUM/LOW)",
        "Cross-repo dependencies mapped",
        "Reference implementation pattern identified",
        "Each repo entry includes: name, project, relevance rationale, impact level"
      ],
      "steps": [
        "Read jira-context.md for context and search terms",
        "Load research methodology from prompts/research/repos.md",
        "Use Sourcebot MCP tools to search for code patterns related to the initiative",
        "Discover repos by searching for domain entities, configuration keys, API patterns",
        "Classify repos by tier (1-6) and impact level (HIGH/MEDIUM/LOW)",
        "Map cross-repo dependencies and integration points",
        "Identify reference implementation",
        "Write structured report to .bot/workspace/product/research-repos.md"
      ],
      "applicable_standards": [".bot/prompts/standards/global/research-output.md"],
      "applicable_agents": [".bot/workflows/kickstart-via-jira/prompts/agents/researcher/AGENT.md"]
    }
  ]
})
```

### Step 3: Verify Creation

After `task_create_bulk` returns, verify:
1. All 3 tasks created successfully (check `created_count == 3`)
2. All 3 tasks have **no dependencies** (they run in parallel)
3. All tasks have `category: "research"` and `research_prompt` fields

Report the result to the user.

## Output

Three research tasks in `.bot/workspace/tasks/todo/`:
1. Deep Internet Research (no dependencies, priority 1)
2. Deep Atlassian Research (no dependencies, priority 1)
3. Deep Sourcebot Research (no dependencies, priority 1)

## Critical Rules

- Create exactly 3 tasks — no more, no fewer
- Use `task_create_bulk` — not individual `task_create` calls
- Include `research_prompt` field on each task
- All 3 tasks are **parallel** — no dependencies between them
- Use the initiative name and Jira key from `jira-context.md` in task names
- Do NOT execute the research — only create the tasks
