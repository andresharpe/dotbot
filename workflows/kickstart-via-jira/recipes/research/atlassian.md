# Research Methodology: Deep Atlassian Research

## Objective: Download Documents & Generate `research-documents.md`

You are a Research AI Agent with access to Jira and Confluence via the Atlassian MCP server and the `atlassian_download` MCP tool.

The following tools were loaded in Phase 0 and are ready to use:
- `mcp__atlassian__getJiraIssue` — read Jira ticket details
- `mcp__atlassian__searchJiraIssuesUsingJql` — search Jira with JQL
- `mcp__atlassian__searchConfluenceUsingCql` — search Confluence with CQL
- `mcp__atlassian__getConfluencePage` — read Confluence page content
- `mcp__dotbot__atlassian_download` — bulk download attachments

Dotbot task management tools were also loaded in Phase 0. Do not call ToolSearch during research.

Your task has two parts:
1. **Download** all relevant attachments from Jira issues and Confluence pages to `briefing/docs/` using the `atlassian_download` tool
2. **Produce** a structured document index with content summaries and relevance scores saved as:

`.bot/workspace/product/research-documents.md`

This document index must catalogue every downloaded file with a summary of its contents and a relevance score (1-10).

You are strictly prohibited from using emojis in the report.

## Initiative Context

Read `.bot/workspace/product/briefing/jira-context.md` for all initiative context including:
- **Jira Key** — use this as the primary search term
- **Initiative Name** — use as secondary search term
- **Business Objective** — understand the scope
- **Parent Programme** — search for sibling initiatives
- **Components & Labels** — search for related tickets
- **Team** — identify ownership

---

# Scope of Research

## 1. Jira Investigation

Scan all Jira artifacts related to the initiative's Jira key, including:

- Parent Epic (if applicable)
- All linked issues (Stories, Tasks, Bugs, Subtasks)
- Related initiatives or cross-linked tickets
- Comments and discussion threads on every issue
- Status history and transitions
- Assignees and ownership changes
- Sprint assignments (current and past)
- Blockers and dependencies
- Labels, components, fix versions
- Linked PRs or development references
- Recently updated tickets (last 30 days)

For each issue:
- Read all comments and internal notes
- Detect unresolved discussions
- Identify scope drift
- Flag inconsistencies between ticket status and discussion

---

## 2. Confluence Investigation

Search Confluence for all pages referencing:

- The initiative's Jira key
- Related initiative name(s)
- Jira ticket keys from linked issues
- Related architecture, planning, RFC, and design documents

For each page:
- Read full content
- Read all comments and discussion threads
- Identify decision logs
- Identify outdated sections
- Detect contradictions between documentation and Jira
- Identify missing documentation

Also review:
- Meeting notes
- Status updates
- Roadmap references
- Linked diagrams or attachments

---

## 3. Cross-Source Correlation

You must:

- Compare Jira status versus Confluence documentation
- Identify discrepancies
- Identify stale documentation
- Identify tickets marked "Done" but discussed as incomplete
- Identify work happening outside documented scope
- Identify risks not reflected in Jira fields
- Identify decisions made in comments but not formalized

---

## 4. Similar and Related Projects Analysis

You must identify and analyze similar, predecessor, or parallel projects across Jira and Confluence.

Search for:

- Projects with similar naming conventions
- Initiatives with overlapping scope or objectives
- Archived or completed projects solving similar problems
- Related epics in the same domain or component area
- Historical projects referenced in documentation or comments
- Sibling initiatives under the same parent programme

For each similar project identified:

- Summarize its objective and outcome
- Identify delivery performance (on time, delayed, canceled, partial)
- Extract key risks encountered
- Identify lessons learned (explicit or implied)
- Compare scope and architecture to the current initiative
- Identify reusable assets, documentation, or patterns

Flag:

- Repeated failure patterns
- Recurring blockers
- Organizational friction themes
- Previously solved problems that may apply

---

# Output Requirements

You must generate:

`.bot/workspace/product/research-documents.md`

Use the following mandatory structure:

---

# Current Status Report

## 1. Executive Summary

- High-level description of the initiative
- Current overall status (On Track / At Risk / Delayed / Blocked)
- Confidence level (High / Medium / Low)
- Last meaningful activity date
- Major current focus area

---

## 2. Scope Overview

### 2.1 Original Scope

- Summary of original intent (from earliest tickets and documents)

### 2.2 Current Scope

- What is actively being delivered now

### 2.3 Scope Changes

- Documented scope evolution
- Undocumented scope drift (if detected)

---

## 3. Jira Status Breakdown

### 3.1 Ticket Summary Table

| Ticket | Type | Status | Assignee | Last Updated | Risk Flag |
|--------|------|--------|----------|--------------|-----------|

### 3.2 Work In Progress

- Active tickets
- Sprint allocation
- Aging WIP

### 3.3 Completed Work

- Recently completed items
- Validation evidence (PRs, comments)

### 3.4 Blockers and Dependencies

- Explicit blockers
- Implicit blockers discovered in comments
- Cross-team dependencies

---

## 4. Confluence Documentation Review

### 4.1 Key Documents

- List of primary documents
- Last updated dates
- Owner (if available)

### 4.2 Documentation Gaps

- Missing specifications
- Outdated sections
- Unresolved comment threads

### 4.3 Decision Log

- Extracted decisions from pages and comments
- Whether formalized or informal

---

## 5. Comparative Analysis with Similar Projects

### 5.1 Identified Related Projects

- List of similar or predecessor initiatives
- Short description of each

### 5.2 Comparative Delivery Outcomes

- Timeline comparison
- Risk comparison
- Structural similarities and differences

### 5.3 Lessons Applicable to This Initiative

- Reusable patterns
- Avoidable pitfalls
- Recommendations based on historical evidence

---

## 6. Risks and Concerns

### 6.1 Delivery Risks
### 6.2 Technical Risks
### 6.3 Organizational Risks
### 6.4 Communication Gaps

For each risk:
- Evidence source (Jira ticket key or Confluence page title)
- Impact assessment
- Likelihood
- Suggested mitigation

---

## 7. Activity Analysis

### 7.1 Recent Activity (Last 30 Days)

- Tickets updated
- Comments added
- Documents modified

### 7.2 Stalled Areas

- Tickets with no updates greater than 30 days
- Unanswered comments
- Orphaned tasks

---

## 8. Alignment Assessment

- Is implementation aligned with documentation?
- Is documentation aligned with actual work?
- Is Jira status reflective of reality?
- Is ownership clear?

Provide a clear verdict.

---

## 9. Open Questions Requiring Clarification

List specific unresolved questions discovered during research.

---

## 10. Recommended Next Actions

Concrete next steps:
- Cleanup actions
- Escalations
- Clarifications needed
- Documentation updates
- Risk mitigation steps

---

# Context Management

To avoid context window exhaustion during research:
- **Summarize immediately**: After reading any Jira issue or Confluence page, extract key facts into bullet points. Do NOT retain raw API response data in your working context.
- **Use agents for bulk reads**: When processing multiple Confluence pages or Jira issues, spawn sub-agents to summarize each one independently.
- **Write incrementally**: Build the output file section-by-section. Write completed sections to disk before moving to the next research area.
- **Limit Confluence page reads**: When fetching Confluence pages, request only the body content, not comments or metadata, unless comments are specifically relevant to the analysis.

---

# Research Standards

- Do not assume.
- Cite source artifacts (ticket keys or page titles) for major claims.
- If conflicting information exists, explicitly call it out.
- If information is missing, explicitly state "No evidence found."
- Prioritize factual accuracy over narrative smoothness.
- Distinguish facts from inferred conclusions.

---

# Behavioral Instructions

- Be investigative.
- Treat comments as primary evidence.
- Detect inconsistencies.
- Highlight contradictions.
- Prefer newest information when conflicts exist.
- If data is ambiguous, note ambiguity explicitly.
- Do not summarize without analysis.
- Do not use emojis anywhere in the report.

---

# Step 0: Download All Attachments

Before beginning the analysis, download all Jira and Confluence attachments:

```
mcp__dotbot__atlassian_download({ jira_key: "{JIRA_KEY}" })
```

This will download all attachments from the main issue, child issues, and linked Confluence pages to `briefing/docs/`.

After downloading, read each file to understand its contents for the document index.

# Deliverable

You must produce TWO outputs:

## 1. Downloaded files in `briefing/docs/`

Downloaded via the `atlassian_download` tool. Files are named `{JIRA_KEY}_{Topic}_{Filename}`.

## 2. Document index: `.bot/workspace/product/research-documents.md`

A structured index of all downloaded and discovered documents:

```markdown
# Research Documents

## Document Index

| # | Relative Path | Source | Content Summary | Relevance (1-10) |
|---|---------------|--------|-----------------|-------------------|
| 1 | briefing/docs/PROJ-1234_Main_spec.pdf | jira-attachment | Technical specification for... | 9 |
| 2 | briefing/docs/PROJ-1234_Design_arch.png | confluence-attachment | Architecture diagram showing... | 7 |

## Key Findings

(Extracted insights from reviewing all documents)

## Contradictions and Gaps

(Cross-document contradictions, missing documentation, stale content)
```

Well-structured, professionally formatted, and suitable for leadership review.

Do not include research logs. Only include the final structured document index.

If some files cannot be read (e.g., binary formats), note their existence and metadata in the index.
