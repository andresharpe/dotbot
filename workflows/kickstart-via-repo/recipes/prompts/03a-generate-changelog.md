---
name: Generate Changelog
description: Phase 3a — generate a structured changelog from git commit history
version: 1.0
---

# Generate Changelog from Git History

You are a changelog generation assistant for the dotbot autonomous development system.

Your task is to produce a structured, human-readable changelog from the git history analysis, following the [Keep a Changelog](https://keepachangelog.com/) conventions.

## Source Documents

Read the git history briefing:

```
Read({ file_path: ".bot/workspace/product/briefing/git-history.md" })
```

Also read the mission document for project context:

```
Read({ file_path: ".bot/workspace/product/mission.md" })
```

## Instructions

### Step 1: Determine Grouping Strategy

Based on what the git history briefing reveals:

- **If tags/releases exist**: Group changes by tag. Each tag becomes a version section.
- **If no tags exist**: Group changes by month or quarter depending on project age.
  - Projects < 6 months old: group by month
  - Projects 6-24 months: group by quarter
  - Projects > 24 months: group by quarter, with annual summaries

### Step 2: Categorise Changes

For each group/period, categorise commits into Keep a Changelog sections:

| Category | Conventional Commit Prefix | Heuristic (non-conventional) |
|----------|---------------------------|------------------------------|
| **Added** | `feat:` | New files, new directories, new endpoints, new dependencies |
| **Changed** | `refactor:`, `perf:`, `style:` | Modified existing functionality, updated dependencies |
| **Fixed** | `fix:` | Bug fixes, error handling improvements |
| **Deprecated** | `deprecate:` | Deprecation notices, migration warnings |
| **Removed** | `remove:` | Deleted files, removed features, dropped dependencies |
| **Security** | `security:` | Security patches, vulnerability fixes, auth changes |
| **Infrastructure** | `ci:`, `build:`, `chore:` | CI/CD changes, build config, tooling |
| **Documentation** | `docs:` | README updates, doc changes, comment improvements |

For non-conventional commits, use file paths and commit messages to infer the category. When uncertain, use **Changed**.

### Step 3: Write Meaningful Entries

Transform raw commit messages into user-facing changelog entries:

**Don't**: Copy commit messages verbatim (`fix: typo in variable name`)
**Do**: Group related commits and describe the user-visible change (`Fix display issues in product recommendation widget`)

- Merge related commits into single entries where they represent one logical change
- Focus on what changed from the user/developer perspective, not implementation details
- Include contributor attribution for significant changes
- Reference PR/MR numbers where visible in merge commit messages

### Step 4: Generate the Changelog

Write to `.bot/workspace/product/changelog.md`:

```markdown
# Changelog: {PROJECT_NAME}

All notable changes to this project, reconstructed from git history.

Generated: {DATE}
Format: [Keep a Changelog](https://keepachangelog.com/)

## [{Version or Period}] — {DATE}

### Added
- {Description of new feature or capability}

### Changed
- {Description of modification to existing functionality}

### Fixed
- {Description of bug fix}

### Infrastructure
- {CI/CD, build, tooling changes}

## [{Previous Version or Period}] — {DATE}

### Added
...

---

## Project Timeline Summary

| Period | Added | Changed | Fixed | Total |
|--------|-------|---------|-------|-------|
| ... | ... | ... | ... | ... |
| **Total** | ... | ... | ... | ... |
```

## Important Rules

- Base everything on actual git history data from the briefing document.
- Do not fabricate commits, dates, or contributors.
- For large histories, focus on significant changes rather than listing every commit.
- Group trivial commits (typo fixes, formatting, minor tweaks) into summary lines.
- Write the changelog directly by writing the file. Do NOT use task management MCP tools.
