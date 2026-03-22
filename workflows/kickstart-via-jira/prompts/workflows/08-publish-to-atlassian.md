---
name: Publish to Atlassian
description: Create/update Jira epic structure and post research documents to Confluence
version: 1.0
---

# Publish to Atlassian

Post research findings and implementation plans to Atlassian (Jira + Confluence) so the broader team has visibility.

## Prerequisites

- `jira-context.md` must exist with Jira key and Atlassian context
- Research artifacts should exist (00-02 at minimum)
- Atlassian MCP server must be available
- Implementation research (04) and plans are recommended but not required

## Your Task

### Step 1: Read Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
```

Also call `research_status` to see which artifacts exist:
```
mcp__dotbot__research_status({})
```

### Step 2: Create/Update Jira Epic Structure

**2a. Update the main initiative ticket:**
```
mcp__atlassian__editJiraIssue({
  issueIdOrKey: "{JIRA_KEY}",
  fields: {
    "description": "(updated description with research summary)"
  }
})
```

Add a comment summarizing research findings:
```
mcp__atlassian__addCommentToJiraIssue({
  issueIdOrKey: "{JIRA_KEY}",
  body: "## Research Summary\n\n(executive summary from implementation research)\n\n### Affected Repos\n(summary table)\n\n### Key Risks\n(top risks)\n\n### Next Steps\n(recommended actions)"
})
```

**2b. Create sub-tasks for each affected repo** (if they don't exist):

For each MEDIUM+ impact repo from `research-repos.md`:
```
mcp__atlassian__createJiraIssue({
  projectKey: "{PROJECT_KEY}",
  issueTypeName: "Sub-task",
  summary: "[{JIRA_KEY}] {RepoName} - Implementation",
  description: "(from deep dive executive summary)",
  parent: "{JIRA_KEY}"
})
```

**2c. Add effort estimates** from deep dives:

For each sub-task created, add a comment with the effort estimate from the deep dive report.

### Step 3: Post Research to Confluence

**3a. Create a Confluence page for the initiative:**
```
mcp__atlassian__createConfluencePage({
  spaceId: "{SPACE_ID}",
  title: "{JIRA_KEY} - {INITIATIVE_NAME} Research",
  body: "(formatted content from implementation research)",
  parentId: "{PARENT_PAGE_ID}"
})
```

Content should include:
- Executive summary
- Affected repos table (from 02)
- Cross-cutting concerns summary (from 03)
- Dependency map (from 05)
- Open questions register (from 06)
- Links to Jira tickets

**3b. Link Jira tickets to Confluence pages:**
```
mcp__atlassian__addCommentToJiraIssue({
  issueIdOrKey: "{JIRA_KEY}",
  body: "Research published to Confluence: [{PAGE_TITLE}|{PAGE_URL}]"
})
```

### Step 4: Verify

- Confirm Jira ticket updated with research summary
- Confirm sub-tasks created for each affected repo
- Confirm Confluence page created with research content
- Confirm cross-links between Jira and Confluence

## Graceful Degradation

If Atlassian MCP is unavailable:
1. Document what would have been published
2. Create a local file `briefing/07_ATLASSIAN_PUBLISH_PENDING.md` with the content
3. Log the failure for manual follow-up

## Output

- Updated Jira initiative ticket
- Sub-tasks per affected repo
- Confluence research page
- Cross-links between Jira and Confluence

## Critical Rules

- Do NOT modify existing Jira ticket fields beyond description and comments
- Do NOT transition ticket statuses — that's a team decision
- Do NOT create duplicate sub-tasks — check for existing ones first
- Preserve existing Confluence page content — create new pages, don't overwrite
- Include the Jira key in all Confluence page titles for searchability
- Format content for readability in Confluence (use proper headings, tables)
