---
name: Pull Request Context
description: Resolve a GitHub or Azure DevOps pull request into reusable workflow context
version: 1.0
---

# Pull Request Context

Resolve the user's pull request into structured product context for workflow launch. This workflow must work when the user pastes a PR URL and when dotbot needs to auto-detect the current PR from the active git branch.

## Context Provided

- The user's prompt may contain a GitHub or Azure DevOps pull request URL.
- Briefing files may exist in `.bot/workspace/product/briefing/`.
- When this prompt is used inside the interview loop, previous Q&A rounds may also be provided.

## Your Task

### Step 1: Resolve the PR

1. Inspect the user's prompt.
2. If it contains a GitHub PR URL like `https://github.com/{owner}/{repo}/pull/{number}`, call:

```text
mcp__dotbot__pr_context({ pr_url: "<the-url>" })
```

3. If it contains an Azure DevOps PR URL like `https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}`, call the same tool with that URL.
4. If no PR URL is present, call:

```text
mcp__dotbot__pr_context({})
```

This tells dotbot to auto-detect the current PR from the current repository and branch.

### Step 2: Write `briefing/pr-context.md`

Always write `.bot/workspace/product/briefing/pr-context.md` with this structure:

```markdown
# Pull Request Context: {PR_TITLE}

## Identity

| Field | Value |
|-------|-------|
| Provider | {github or azure-devops} |
| Repository | {repository or project/repo} |
| PR URL | {PR_URL} |
| PR ID | {PR_NUMBER_OR_ID} |
| Source Branch | {SOURCE_BRANCH} |
| Target Branch | {TARGET_BRANCH} |
| Author | {AUTHOR} |
| State | {STATE} |

## Summary

- **Title**: {PR_TITLE}
- **Intent**: 2-4 sentence summary of what this PR is trying to achieve.
- **Why now**: infer timing or driver from the PR description and linked issues.

## Description

{PR_DESCRIPTION}

If the description is empty, write `<!-- UNRESOLVED: pr_description -->`.

## Linked Issues

| Key | Title | State | Type | URL |
|-----|-------|-------|------|-----|
| ... | ... | ... | ... | ... |

If no issues are linked, state that explicitly.

## Changed Files

| Path | Change Type | Notes |
|------|-------------|-------|
| ... | ... | 1-line implication |

Summarize the changed files into logical clusters such as domain logic, tests, API surface, docs, or infrastructure.

## Impact Assessment

- **Likely user-visible impact**: ...
- **Likely system boundaries touched**: ...
- **Testing surface implied by the diff**: ...
- **Deployment or rollout concerns**: ...

## Open Questions

- List only the questions that remain after reading the PR context.
- If none remain, say `No blocking questions from PR context.`

## Original Prompt

{USER_PROMPT}
```

Ground every claim in the PR description, linked issues, or changed files. Do not invent architecture that the PR context does not support.

### Step 3: Interview-mode output handling

If the surrounding instructions explicitly tell you to decide between `clarification-questions.json` and `interview-summary.md`, do that after writing `pr-context.md`:

- Write `clarification-questions.json` only when the PR context still leaves material ambiguity about business intent, scope boundaries, rollout requirements, or success criteria.
- Otherwise write `interview-summary.md` that synthesizes the PR context and any answered questions into a coherent brief for downstream phases.

In interview mode, write exactly one of those two files.
In non-interview mode, do not write either file unless the surrounding instructions require it.

## Critical Rules

- Always create `.bot/workspace/product/briefing/pr-context.md`.
- Use `pr_context` as the source of truth for PR description, linked issues, and changed files.
- If the tool returns an error, surface the failure clearly instead of inventing PR details.
- Keep the document concise and specific. It should be easy for later phases to scan.
