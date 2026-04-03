---
name: Kickstart Interview (Multi-Repo)
description: Override — auto-resolve initiative from Atlassian, then ask follow-up questions if needed
version: 1.1
---

# Kickstart: Auto-Resolve from Atlassian

You are initializing a multi-repo initiative. You will auto-resolve the initiative context from Atlassian (Jira + Confluence) using the user's prompt, then decide whether follow-up questions are needed.

## Context Provided

- **User's prompt**: A short description containing a Jira key (e.g., "PROJ-1234 Payment Gateway Upgrade")
- **Briefing files**: Any attached reference materials

## Your Task

### Step 1: Parse the Jira Key

Extract the Jira key from the user's prompt using the pattern `[A-Z]{2,10}-\d+`.

If no Jira key is found:
- Use the prompt text as the initiative name
- Skip Atlassian resolution
- Populate `jira-context.md` from prompt text + uploaded files
- Mark unresolved fields with `<!-- UNRESOLVED: field_name -->`

### Step 1b: Discover Atlassian Cloud ID

Before making any Jira or Confluence calls, you need the Atlassian cloud ID.

Call:
```
mcp__atlassian__getAccessibleAtlassianResources()
```

From the response, extract the `id` field of the first (or only) cloud site. Store this as `{CLOUD_ID}` for all subsequent Atlassian MCP calls.

If this call fails (MCP server unavailable), skip to Graceful Degradation.

### Step 2: Resolve from Jira

Use the Atlassian MCP server to fetch initiative context:

**2a. Get the main issue:**
```
mcp__atlassian__getJiraIssue({ cloudId: "{CLOUD_ID}", issueIdOrKey: "{JIRA_KEY}" })
```

Extract:
- `summary` → initiative name
- `description` → business objective
- `status` → current status
- `parent` → parent/programme key
- `components` → affected systems
- `labels` → initiative labels
- `assignee` → primary assignee
- `created` / `updated` → dates
- Custom fields → team members (BA, Architect, PM, SDM)
- `issuelinks` → related tickets

**2b. Get child issues:**
```
mcp__atlassian__searchJiraIssuesUsingJql({
  cloudId: "{CLOUD_ID}",
  jql: "parent = {JIRA_KEY}",
  limit: 50
})
```

**2c. Get linked issues:**
```
mcp__atlassian__searchJiraIssuesUsingJql({
  cloudId: "{CLOUD_ID}",
  jql: "issuekey in linkedIssues({JIRA_KEY})",
  limit: 50
})
```

**2d. Resolve parent programme:**

If the main issue has a parent key:
```
mcp__atlassian__getJiraIssue({ cloudId: "{CLOUD_ID}", issueIdOrKey: "{PARENT_KEY}" })
```

Then search for sibling initiatives:
```
mcp__atlassian__searchJiraIssuesUsingJql({
  cloudId: "{CLOUD_ID}",
  jql: "parent = {PARENT_KEY}",
  limit: 20
})
```

From siblings, identify the best **reference implementation** candidate:
- Same programme, completed or in-progress status, similar components
- If the user's prompt mentions a reference, use that instead

**2e. Search Confluence:**
```
mcp__atlassian__searchConfluenceUsingCql({
  cloudId: "{CLOUD_ID}",
  cql: "text ~ \"{JIRA_KEY}\" OR text ~ \"{INITIATIVE_NAME}\"",
  limit: 20
})
```

Read up to `max_pages_to_read` (from settings, default 10) key pages:
```
mcp__atlassian__getConfluencePage({ cloudId: "{CLOUD_ID}", pageId: "{PAGE_ID}" })
```

Extract page title, space, and a ~500 character excerpt from each page.

### Step 3: Read Settings

Load profile settings for organisation-specific values:
```
Read({ file_path: ".bot/defaults/settings.default.json" })
```

Also check `.env.local` for ADO org URL (loaded into process environment by profile-init.ps1).

### Step 4: Write `jira-context.md`

Write a clean, machine-readable Jira reference to `.bot/workspace/product/briefing/jira-context.md`:

```markdown
# Jira Context: {INITIATIVE_NAME}

## Metadata

| Field | Value |
|-------|-------|
| Jira Key | {JIRA_KEY} |
| Summary | {SUMMARY} |
| Status | {STATUS} |
| Parent | {PARENT_KEY} -- {PARENT_SUMMARY} |
| Strategic Programme | {PROGRAMME_NAME} |
| Created | {CREATED_DATE} |
| Updated | {UPDATED_DATE} |
| URL | {JIRA_URL} |

## Team

| Role | Name | Jira Account |
|------|------|--------------|
| Assignee | {ASSIGNEE} | {ASSIGNEE_ID} |
| Business Analyst | {BA} | {BA_ID} |
| Architect | {ARCHITECT} | {ARCHITECT_ID} |
| Project Manager | {PM} | {PM_ID} |
| SDM | {SDM} | {SDM_ID} |

> Team members resolved from Jira assignee + custom fields. Unresolved roles left blank.

## Business Objective

{JIRA_DESCRIPTION}

## Components & Labels

- **Components**: {COMPONENTS_LIST}
- **Labels**: {LABELS_LIST}

## Child Issues

| Key | Summary | Status | Assignee | Type |
|-----|---------|--------|----------|------|
(populated from Step 2b)

## Linked Issues

| Key | Summary | Link Type | Status | Project |
|-----|---------|-----------|--------|---------|
(populated from Step 2c)

## Confluence Documentation

| Page Title | Page ID | Space | Excerpt |
|------------|---------|-------|---------|
(populated from Step 2e)

> Up to max_pages_to_read pages fetched. Excerpts are first ~500 chars of body.

## Programme Context

- **Parent Programme**: {PARENT_KEY} -- {PROGRAMME_NAME}
- **Sibling Initiatives**:

| Key | Summary | Status | Relevance |
|-----|---------|--------|-----------|
(populated from Step 2d)

## Reference Implementation

- **Recommended Reference**: {REFERENCE_KEY} -- {REFERENCE_NAME}
- **Rationale**: {REFERENCE_RATIONALE}

> Auto-selected from sibling initiatives based on: same programme, completed/in-progress status,
> similar components. User can override by mentioning a reference in their prompt.

## Organisation Settings

| Setting | Value |
|---------|-------|
| Azure DevOps Org | {ADO_ORG_URL} |
| ADO Projects | {ADO_PROJECTS} |
| Atlassian Cloud ID | {ATLASSIAN_CLOUD_ID} |
| Confluence Spaces | {CONFLUENCE_SPACES} |

> Populated from settings.default.json and .env.local.

## User-Provided Context

- **Original Prompt**: "{USER_PROMPT}"
- **Reference Hint**: {REFERENCE_HINT}
- **Uploaded Files**:
{UPLOADED_FILES_LIST}
```

For any field that could not be resolved, use `<!-- UNRESOLVED: field_name -->` as the value.

### Step 5: Decide — Follow-Up Questions or Complete

After writing `jira-context.md`, count the `<!-- UNRESOLVED: ... -->` markers. Also consider whether the business objective, team composition, reference implementation, or scope are sufficiently clear.

**Check for previous Q&A rounds**: If earlier interview rounds provided answers (available in your context as previous Q&A), incorporate those answers — do NOT re-ask questions that were already answered.

#### Decision A: Significant gaps remain → Ask follow-up questions

If there are 3+ unresolved fields, or if critical fields (business objective, scope, reference implementation) are unclear, write `.bot/workspace/product/clarification-questions.json`:

```json
{
  "questions": [
    {
      "id": "q1",
      "question": "Clear, specific question about an unresolved field",
      "context": "Why this matters — what Atlassian could not resolve",
      "options": [
        { "key": "A", "label": "Option label", "rationale": "Why you might choose this" },
        { "key": "B", "label": "Option label", "rationale": "Why you might choose this" }
      ],
      "recommendation": "A"
    }
  ]
}
```

Focus questions on:
- Fields marked `<!-- UNRESOLVED -->` in `jira-context.md`
- Missing context that Atlassian didn't provide (architecture decisions, scope boundaries, deployment targets)
- Ambiguous business objectives that need user clarification
- Reference implementation selection if multiple candidates exist

Rules for questions:
- Each question must have 2-5 options (A through E)
- Option A should be the recommended choice
- Provide clear rationale for each option
- No artificial limit on question count — ask as many as genuinely needed
- Do NOT re-ask questions already answered in previous rounds

#### Decision B: Resolution is sufficient → Complete

If all critical fields are resolved (either from Atlassian, the user's prompt, uploaded files, or previous Q&A rounds), write `.bot/workspace/product/interview-summary.md`:

```markdown
# Interview Summary

## Resolution Method
- **Source**: Atlassian MCP (Jira + Confluence)
- **Jira Key**: {JIRA_KEY}
- **Pages Read**: {N} Confluence pages
- **Child Issues**: {N} found
- **Linked Issues**: {N} found
- **Sibling Initiatives**: {N} found

## Unresolved Fields
{LIST_OF_REMAINING_UNRESOLVED_FIELDS_OR_NONE}

## MCP Errors (if any)
{LIST_OF_FAILED_MCP_CALLS_OR_NONE}

## Clarification Log

### Phase 0: Fetch Jira Context — Round 1
| # | Question | Answer (verbatim) | Interpretation | Timestamp |
|---|----------|--------------------|----------------|-----------|
| q1 | {question text} | {user's verbatim answer} | {your interpretation of the answer and its implications} | {ISO timestamp} |
```

The **Clarification Log** section is an append-only log that spans all phases. Phase 0 writes the initial entries. Subsequent phases (01, 04, etc.) will append their own sections via the runtime when their questions are answered.

If previous Q&A rounds occurred, include entries in the Clarification Log for each round (e.g., `### Phase 0: Fetch Jira Context — Round 1`, `### Phase 0: Fetch Jira Context — Round 2`).

If no Q&A rounds occurred (auto-resolved cleanly), omit the Clarification Log section entirely.

### Graceful Degradation

If Atlassian MCP is unavailable or returns errors:

1. Populate `jira-context.md` from the user's prompt text + any uploaded files
2. Mark unresolved fields with `<!-- UNRESOLVED: field_name -->`
3. Log which MCP calls failed
4. Write `clarification-questions.json` asking the user to provide the missing context manually — the interview loop will present these questions in the UI

## Critical Rules

- Always write `briefing/jira-context.md` first (Steps 1-4)
- Then write **exactly one** of: `clarification-questions.json` OR `interview-summary.md`
- **NEVER** write both `clarification-questions.json` and `interview-summary.md` in the same round
- Do NOT create any other files (no mission.md, no tech-stack.md, etc.)
- Do NOT use task management tools
- You may ask clarification questions if Atlassian resolution leaves significant gaps
- On round 2+, you still have `jira-context.md` from round 1 — do not re-write it, just decide between questions and summary
