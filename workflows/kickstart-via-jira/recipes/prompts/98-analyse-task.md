---
name: Pre-flight Task Analysis (Multi-Repo)
description: Research-aware override of 98-Analyse — dispatches research methodology for research-category tasks
version: 1.0
---

# Pre-flight Task Analysis (Multi-Repo Override)

You are an autonomous AI coding agent performing **pre-flight analysis** of a task. Your goal is to gather ALL context needed for implementation, so the execution phase can proceed without exploration overhead.

## Phase 0: Load Required Tools

**Built-in tools** (`WebSearch`, `WebFetch`, `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`) are always available — never use ToolSearch for them.

**Step 1 — Load core dotbot tools** (always, all in parallel):

```
ToolSearch({ query: "select:mcp__dotbot__task_mark_analysing" })
ToolSearch({ query: "select:mcp__dotbot__task_mark_analysed" })
ToolSearch({ query: "select:mcp__dotbot__task_mark_needs_input" })
ToolSearch({ query: "select:mcp__dotbot__task_mark_skipped" })
ToolSearch({ query: "select:mcp__dotbot__research_status" })
ToolSearch({ query: "select:mcp__dotbot__plan_get" })
ToolSearch({ query: "select:mcp__dotbot__plan_create" })
```

**Step 2 — Load research-specific tools** (in the same parallel batch, based on `research_prompt`):

| research_prompt | Additional ToolSearch calls |
|---|---|
| `repos.md` | `select:mcp__sourcebot__search_code`, `select:mcp__sourcebot__list_repos`, `select:mcp__sourcebot__read_file`, `select:mcp__sourcebot__list_tree`, `select:mcp__sourcebot__ask_codebase` |
| `repo-deep-dive.md` | All sourcebot tools above + `select:mcp__dotbot__repo_clone`, `select:mcp__dotbot__repo_list` |
| `atlassian.md` | `select:mcp__dotbot__atlassian_download`, `select:mcp__atlassian__getJiraIssue`, `select:mcp__atlassian__searchJiraIssuesUsingJql`, `select:mcp__atlassian__searchConfluenceUsingCql`, `select:mcp__atlassian__getConfluencePage` |
| `public.md` | **None** — internet research uses only built-in WebSearch and WebFetch |
| _(not research)_ | None |

Issue all ToolSearch calls from Steps 1 and 2 in a **single parallel batch**. Do not call ToolSearch again after Phase 0.

---

## Session Context

- **Session ID:** {{SESSION_ID}}
- **Task ID:** {{TASK_ID}}
- **Task Name:** {{TASK_NAME}}

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

## Research Category Dispatch

**This is the key override.** Before running the standard analysis protocol, check if this task is a research task.

### Check: Is this a research task?

```
IF task.category == "research" AND task has a "research_prompt" field:
    → Use RESEARCH ANALYSIS MODE (below)
ELSE:
    → Use STANDARD ANALYSIS MODE (Phase 1-10 from default 98-analyse-task)
```

---

## RESEARCH ANALYSIS MODE

When the task category is `research` and the task has a `research_prompt` field, the analysis phase operates differently. Instead of the standard 10-phase protocol (entity detection, file discovery, etc.), the analysis loads a research methodology prompt and prepares the execution phase for research output.

### Research Phase 1: Mark Task In Analysis

```
mcp__dotbot__task_mark_analysing({ task_id: "{{TASK_ID}}" })
```

### Research Phase 2: Load Initiative Context

Read the initiative document for all context needed by the research methodology:

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
```

Extract from `jira-context.md`:
- **Jira Key** (e.g., `PROJ-1234`)
- **Initiative Name** (e.g., `Payment Gateway Upgrade`)
- **Business Objective**
- **Parent Programme**
- **Reference Implementation** (if identified)
- **Organisation Settings** (ADO org URL, Atlassian cloud ID, etc.)
- **Team members**

These values will be substituted into the research methodology prompt.

> **Path reference** — Initiative context is in `briefing/` but research outputs are one level up:
> - Initiative context: `.bot/workspace/product/briefing/jira-context.md`
> - Research outputs: `.bot/workspace/product/research-documents.md`, `research-internet.md`, `research-repos.md`
> - Deep dive outputs: `.bot/workspace/product/briefing/repos/{RepoName}.md`

### Research Phase 3: Load Research Methodology

Load the research prompt specified in the task's `research_prompt` field:

```
Read({ file_path: ".bot/recipes/research/{{TASK.research_prompt}}" })
```

The research prompt is a **methodology document** — it defines:
- What to research
- How to structure the investigation
- What output sections are required
- Quality standards and behavioral instructions

### Research Phase 4: Load Prior Research (if applicable)

If this task has dependencies, the dependent research outputs should already exist. Load them for context:

- `.bot/workspace/product/research-documents.md` — from Atlassian research
- `.bot/workspace/product/research-internet.md` — from public research
- `.bot/workspace/product/research-repos.md` — from repo scan

Only load what exists and is relevant to this task's methodology.

### Research Phase 5: Determine Working Directory

Check if the task has a `working_dir` field:

- If `working_dir` is set (e.g., `repos/OrderService`): the execution phase should operate in that directory relative to the project root
- If not set: the execution phase operates in the project root as normal

For deep dive tasks with `external_repo` field:
1. Check if the repo is already cloned at `repos/{RepoName}/`
2. If not, note that the execution phase should call `repo_clone` first

### Research Phase 6: Prepare Execution Context

Package the analysis for the execution phase (99-autonomous-task):

```
mcp__dotbot__task_mark_analysed({
  task_id: "{{TASK_ID}}",
  analysis: {
    mode: "research",
    research_prompt: "{{TASK.research_prompt}}",
    initiative: {
      jira_key: "<from jira-context.md>",
      name: "<from jira-context.md>",
      business_objective: "<from jira-context.md>",
      reference_implementation: "<from jira-context.md>",
      ado_org_url: "<from jira-context.md or .env.local>"
    },
    prior_research: [
      "<full relative paths, e.g. .bot/workspace/product/research-documents.md>"
    ],
    working_dir: "<from task, or null>",
    external_repo: "<from task, or null>",
    output_path: "<expected output file path from methodology>",
    methodology_summary: "<brief summary of what the research prompt instructs>"
  }
})
```

### Research Phase 7: User Interview (If Needed)

If `needs_interview` is `true`, ask clarifying questions about the research scope before completing analysis. Use the same `task_mark_needs_input` pattern as the default 98.

---

## STANDARD ANALYSIS MODE

When the task is NOT a research task, use the standard 10-phase analysis protocol. The only additions to the default behavior are:

### Addition 1: Initiative Context (prepend to Phase 6)

Before extracting product context, also read:
```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
```

Include the initiative's Jira key, business objective, and reference implementation in the `product_context` section of the analysis output.

### Addition 2: Working Directory (add to Phase 4)

If the task has a `working_dir` field, include it in the analysis output so the execution phase knows to operate in a different directory.

### Addition 3: Research Outputs as Context

If research outputs exist in `.bot/workspace/product/briefing/`, reference relevant ones in the product context. Don't read them all — only those that are relevant to the specific task being analysed.

### Addition 4: Environment Pre-flight (before Phase 3)

Before file discovery, verify the build environment in the task's `working_dir` (or project root). This applies to implementation tasks only (not research tasks).

#### 4a. Git working tree state

Run `git status --porcelain` in the working directory. Document any unexpected changes in `implementation.pre_existing_changes`. On Windows, check `git config core.longpaths` — if not `true`, note as a risk for repos with deep paths.

#### 4b. Detect tech stack and invoke pre-flight skill

Detect the project's build system by checking for marker files:

| Marker file | Tech stack |
|-------------|-----------|
| `*.sln` or `*.csproj` | dotnet |
| `package.json` | node |
| `pom.xml` or `build.gradle` | java |
| `requirements.txt` or `pyproject.toml` | python |

Then check if a matching pre-flight skill exists:

```
Glob({ pattern: ".bot/recipes/skills/tech-preflight-{detected-tech}/SKILL.md" })
```

If found, read and follow the skill's instructions. The skill will handle:
- SDK/runtime compatibility checks
- Project dependency graph mapping
- Baseline build snapshot
- Architecture constraint identification

If no matching skill exists, perform a generic baseline:
- Attempt to run the project's standard build command (if identifiable)
- Record pass/fail and any error output

#### 4c. Include findings in analysis output

Add an `environment` key to the `task_mark_analysed` call:
```json
{
  "environment": {
    "tech_stack": "dotnet",
    "pre_existing_changes": "...",
    "git_longpaths": true,
    "sdk_gaps": [],
    "dependency_graph": {},
    "baseline_build": { "status": "pass", "error_count": 0, "warning_count": 42, "pre_existing_errors": [] }
  }
}
```

### Default Phases (1-10)

All other phases proceed exactly as specified in the default 98-analyse-task workflow:
1. Mark task analysing
2. User interview (if needed)
3. Entity detection
4. File discovery
5. Dependency validation
6. Standards mapping
7. Product context extraction (+ initiative context)
8. Implementation guidance
9. Clarifying questions (if needed)
10. Split proposal (if needed) → Complete analysis

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

---

## Anti-Patterns

### Do Not Re-read the Full Research Prompt at Execution Time
The analysis phase packages everything the executor needs. The research prompt is a methodology guide for analysis, not an execution script.

### Do Not Skip Initiative Context for Research Tasks
Every research task needs initiative context — the Jira key, business objective, and reference implementation drive the research methodology.

### Do Not Over-Package
For research tasks, the executor needs: the methodology summary, initiative context, prior research references, and output path. It does NOT need entity models, file inventories, or insertion points.

---

## Success Criteria

### For Research Tasks:
- [ ] Task marked as analysing
- [ ] Initiative context loaded and extracted
- [ ] Research methodology loaded and summarized
- [ ] Prior research loaded (if dependencies met)
- [ ] Working directory and external repo noted
- [ ] Output path identified
- [ ] Task marked as analysed with research-mode context

### For Standard Tasks:
- [ ] All default 98 success criteria met
- [ ] Initiative context included in product context
- [ ] Working directory noted (if applicable)
- [ ] Relevant research outputs referenced

---

## Important Reminders

1. **You are NOT implementing** — only researching and preparing
2. **Research vs Standard** — check the category first, then follow the right path
3. **Initiative context is always relevant** — read jira-context.md for both modes
4. **Package context tightly** — the execution phase should not need to re-explore
5. **Note risks and gotchas** — help implementation avoid pitfalls
