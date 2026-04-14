---
name: Gap Analysis Task Groups
description: Phase 5a — identify gaps in the existing codebase and create task groups for addressing them
version: 1.0
---

# Gap Analysis Task Groups

You are a gap analysis assistant for the dotbot autonomous development system.

Your task is to examine the existing project's product documents, briefings, and architectural decisions to identify forward-looking improvements — gaps in testing, documentation, tech debt, security, and incomplete features — and produce a `task-groups.json` manifest for addressing them.

## Source Documents

Read all available context:

```
Read({ file_path: ".bot/workspace/product/briefing/repo-scan.md" })
Read({ file_path: ".bot/workspace/product/briefing/git-history.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
Read({ file_path: ".bot/workspace/product/tech-stack.md" })
Read({ file_path: ".bot/workspace/product/entity-model.md" })
```

Also read accepted architectural decisions:
```javascript
mcp__dotbot__decision_list({ status: "accepted" })
```

If the changelog and retrospective roadmap exist, read those too for additional context:
```
Read({ file_path: ".bot/workspace/product/changelog.md" })        // may not exist
Read({ file_path: ".bot/workspace/product/retrospective-roadmap.md" })  // may not exist
```

## Instructions

### Step 1: Identify Gap Categories

Analyse the project across these dimensions:

#### Missing Tests
- Areas with no test coverage (from repo scan assessment)
- Critical paths without integration tests
- Missing edge case coverage
- Absent test infrastructure (test helpers, fixtures, CI test pipeline)

#### Tech Debt
- Outdated dependencies (check versions against known current releases)
- Deprecated API usage
- Code patterns that could be modernised
- Inconsistent patterns across the codebase
- TODO/FIXME/HACK comments in the code

#### Documentation Gaps
- Missing or stale README sections
- Undocumented API endpoints
- Missing architectural documentation
- Absent onboarding/setup guides
- Missing inline documentation for complex logic

#### Incomplete Features
- Partially implemented features (stubs, empty handlers, placeholder UI)
- Features referenced in docs but not fully built
- Scaffolding that exists without implementation

#### Infrastructure Gaps
- Missing CI/CD pipeline or incomplete pipeline
- No containerisation where appropriate
- Missing health checks or monitoring
- No linting/formatting configuration
- Missing development environment automation

#### Security Concerns
- Missing input validation on API boundaries
- Absent authentication or authorisation checks
- Potential secrets in code or config
- Missing CORS, CSP, or other security headers
- No dependency vulnerability scanning

### Step 2: Prioritise Gaps

Not all gaps are equal. Prioritise based on:
1. **Impact on reliability**: Gaps that could cause production incidents
2. **Developer experience**: Gaps that slow down future development
3. **Security risk**: Gaps that expose the application to attack
4. **Documentation debt**: Gaps that prevent new contributors from being effective

### Step 3: Create Task Groups

Organise identified gaps into **3-8 task groups**. Each group should be a coherent collection of related improvements.

Write `.bot/workspace/product/task-groups.json`:

```json
{
  "generated_at": "ISO-8601 timestamp",
  "project_name": "Project name from mission.md",
  "analysis_type": "gap-analysis",
  "total_groups": 5,
  "groups": [
    {
      "id": "grp-1",
      "name": "Test Coverage Foundation",
      "order": 1,
      "description": "Establish test infrastructure and add coverage for critical paths currently untested",
      "effort_days": 5,
      "scope": [
        "Set up test framework and test helpers",
        "Add unit tests for core business logic in {specific area}",
        "Add integration tests for {specific endpoints/flows}",
        "Configure CI to run tests on PR"
      ],
      "acceptance_criteria": [
        "Test framework is configured and running",
        "Core business logic has >80% branch coverage",
        "CI pipeline runs tests on every PR"
      ],
      "estimated_task_count": 5,
      "depends_on": [],
      "priority_range": [1, 15],
      "category_hint": "testing"
    }
  ]
}
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique group ID: `grp-1`, `grp-2`, etc. |
| `name` | Yes | Human-readable group name |
| `order` | Yes | Execution order (1 = first) |
| `description` | Yes | 1-2 sentence summary of what this group addresses |
| `effort_days` | Yes | Estimated developer-days (1-20) |
| `scope` | Yes | Array of specific items to address (these become task seeds) |
| `acceptance_criteria` | Yes | Group-level success conditions |
| `estimated_task_count` | Yes | Expected number of tasks (2-8 per group) |
| `depends_on` | Yes | Array of group IDs this depends on (empty for root groups) |
| `priority_range` | Yes | `[min, max]` — non-overlapping priority range |
| `category_hint` | Yes | Default category: `testing`, `tech-debt`, `documentation`, `feature`, `infrastructure`, `security` |

### Guidelines

- **Be specific**: Reference actual files, directories, and code patterns from the repo scan. "Add tests for the auth module" is better than "improve test coverage".
- **Be realistic**: Only identify gaps that are genuinely worth addressing. Not every project needs every type of improvement.
- **3-8 groups**: Fewer than 3 means groups are too broad; more than 8 means too granular.
- **Each scope item** should map to roughly 1-2 tasks when expanded.
- **Priority ranges** must not overlap between groups.
- **Total estimated_task_count** typically 10-40 across all groups.
- **Total effort_days** typically 10-40, reflecting real developer time.
- **Respect existing decisions**: If an architectural decision record explains why something was done a certain way, don't create tasks to undo it.

## Output

Write `.bot/workspace/product/task-groups.json` and confirm with a brief summary:
- Number of groups created
- Total estimated tasks
- Total estimated effort (days)
- Group names with their categories and order

## Important Rules

- Do NOT use `task_create` or `task_create_bulk` — task creation happens in Phase 5b.
- Write the JSON file directly.
- **Large files**: If a file read fails due to token limits, re-read with `offset` and `limit` parameters. Do NOT skip large files.
- Base all gaps on evidence from the briefing documents. Do not invent problems.
- If the project is in excellent shape with few gaps, create fewer groups. 3 groups is fine.
