<!-- Used by 'planning' process type only. NOT used during kickstart. -->
---
name: Plan Roadmap
description: Automatic roadmap generation from product documents using dotbot MCP tools
version: 3.0
---

# Roadmap Planning Workflow

This workflow automatically generates a comprehensive task roadmap from your product specification documents.

## Goal
Transform product specifications into granular, context-window-sized tasks tracked in `.bot/workspace/tasks/todo/` using the `task_create_bulk` MCP tool.

## Agent Teams Strategy

When agent teams are available, use a team-based approach for parallel analysis:

### Team Composition

1. **Architect (Lead)** — Reads all product docs, identifies implementation phases, designs the dependency graph, and coordinates the team.
2. **Feature Analyst: Infrastructure & Foundation** — Handles project setup, database, configuration, hosting, CI/CD tasks.
3. **Feature Analyst: Core & Integrations** — Handles primary business logic, external API integrations, and service layer tasks.
4. **Feature Analyst: Background & Intelligence** — Handles background jobs, scheduled tasks, AI integration, rules engines, and notification systems.

### Team Workflow

1. **Lead** reads all product docs and creates a shared brief: functional areas, entity relationships, technology constraints, and phase boundaries.
2. **Lead** assigns functional areas to each Feature Analyst.
3. Each **Feature Analyst** independently:
   - Analyzes their assigned area
   - Generates task breakdowns with effort estimates, acceptance criteria, and dependencies
   - Creates tasks via `task_create_bulk`
4. **Lead** synthesizes results:
   - Resolves cross-cutting dependencies between analysts' tasks
   - Verifies no duplicate tasks exist (use `task_list` to check)
   - Validates dependency chains are correct
   - Generates `roadmap-overview.md`

### Fallback

If agent teams are not available, execute all steps sequentially in a single session.

## Required Product Documents

Before running this workflow, ensure these files exist in `.bot/workspace/product/`:

| Document | Path | Purpose |
|----------|------|----------|
| Mission | `.bot/workspace/product/mission.md` | Core principles, goals, target audience |
| Tech Stack | `.bot/workspace/product/tech-stack.md` | Technology choices and libraries |
| Entity Model | `.bot/workspace/product/entity-model.md` | Data model and entity relationships |

Optional but recommended:
- `.bot/workspace/product/prd.md` — Full product requirements document (if available)
- Any other docs in `.bot/workspace/product/` — Read all for additional context

## Automatic Execution Process

### Step 1: Load All Product Context

**Read ALL product documents:**

1. `.bot/workspace/product/mission.md` — Core principles and goals
2. `.bot/workspace/product/tech-stack.md` — Technology stack and libraries
3. `.bot/workspace/product/entity-model.md` — Data model and relationships
4. `.bot/workspace/product/prd.md` — Full specification (if exists)
5. Any other `.md` files in `.bot/workspace/product/` — Additional context

**Extract from these documents:**
- Major functional areas and features
- Technical architecture and patterns
- Entity relationships and data flow
- Background jobs and scheduled tasks
- Integration points (APIs, external services)
- Testing requirements
- Deployment considerations

### Step 2: Identify Implementation Phases

Based on the product docs and entity model, identify natural implementation phases:

**Phase 1: Foundation**
- Project structure and solution setup
- Database schema and migrations
- Core entity definitions
- Configuration loading
- Basic API host setup

**Phase 2: External Integrations**
- Authentication setup (Graph, etc.)
- External API clients
- Webhook/polling infrastructure

**Phase 3: Core Features**
- Primary business logic
- Command/query handlers
- Service layer implementations

**Phase 4: Background Processing**
- Scheduled jobs
- Proactive features
- Notification system

**Phase 5: Intelligence & Rules**
- AI integration
- Rules engine
- Pattern detection

**Phase 6: Polish & Testing**
- Integration tests
- Error handling improvements
- Performance optimization

Adapt these phases to fit the actual project. Not all projects need all phases.

### Step 3: Generate Task Breakdown

For each feature/component identified in the product docs:

**Apply the breakdown algorithm:**
1. Identify the functional area (Email, Calendar, Rules, etc.)
2. List the specific capabilities within that area
3. Break each capability into implementation tasks
4. Ensure each task is:
   - Completable in 1-4 hours of focused work
   - Independently testable where possible
   - Small enough to fit in a single LLM context window

**Task sizing guide:**
| Effort | Typical Duration | Examples |
|--------|-----------------|----------|
| XS | < 1 hour | Add field to entity, simple config |
| S | 1-2 hours | Simple command handler, basic query |
| M | 2-4 hours | Feature with tests, integration work |
| L | 4-8 hours | Complex feature, multiple components |
| XL | 1-2 days | Major subsystem, significant refactoring |

### Step 4: Define Categories

Assign each task to a category:

| Category | Use For |
|----------|----------|
| `infrastructure` | Project setup, database, hosting, CI/CD |
| `core` | Essential functionality required for MVP |
| `feature` | User-facing features and capabilities |
| `enhancement` | Improvements to existing functionality |
| `ui-ux` | Interface and user experience work |
| `bugfix` | Corrections to existing functionality |

### Step 5: Map Dependencies

**Dependency rules:**
1. Infrastructure tasks have no dependencies (they come first)
2. Core entities depend on database setup
3. Feature handlers depend on relevant entities
4. Background jobs depend on the features they orchestrate
5. Integration tests depend on the features they test

**Auto-assign priorities based on dependency depth:**
- Priority 1-10: Infrastructure (no dependencies)
- Priority 11-30: Core entities and services
- Priority 31-60: Features and integrations
- Priority 61-80: Background jobs and proactive features
- Priority 81-100: Polish, optimization, extended testing

### Step 6: Create Tasks via MCP

**Use `task_create_bulk` to create all tasks:**

```javascript
task_create_bulk({
  tasks: [
    {
      name: "Initialize solution and project structure",
      description: "Create solution with projects as defined in product docs. Configure project references and add core packages from tech-stack.md.",
      category: "infrastructure",
      priority: 1,
      effort: "M",
      dependencies: [],
      acceptance_criteria: [
        "Solution builds successfully",
        "All projects created with correct references",
        "Core packages installed"
      ],
      steps: [
        "Create solution file",
        "Create each project from product doc structure",
        "Add project references",
        "Install packages from tech-stack.md"
      ]
    }
    // ... continue for all identified tasks
  ]
})
```

**Batching:** If the total exceeds 50 tasks, create in batches of 20-30. When batching:
1. Create infrastructure/foundation tasks first
2. Note the IDs returned from each batch
3. Use those IDs as dependencies in subsequent batches

### Step 7: Cross-Reference and Validate

After all tasks are created:

1. Call `task_list` to retrieve all tasks
2. Verify no duplicate tasks exist (similar names or overlapping scope)
3. Verify dependency chains are valid (no circular dependencies, no missing references)
4. Verify all functional areas from the product docs are covered

### Step 8: Generate Roadmap Overview

Generate `.bot/workspace/product/roadmap-overview.md`:

```markdown
# Task Roadmap Overview

Generated: [Date]
Total Tasks: [Count]
Estimated Total Effort: [Sum]

## Executive Summary
[Brief description based on mission.md]

## Task Breakdown by Category

### Infrastructure ([count]) - [total effort]
- [Task name] ([effort]) - [1-line description]

### Core ([count]) - [total effort]
- [Task name] ([effort]) - [1-line description]

### Features ([count]) - [total effort]
- [Task name] ([effort]) - [1-line description]

## Implementation Phases

### Phase 1: Foundation
Goal: [Goal]
Tasks: [list with priorities]

### Phase 2: Core Features
...

## Dependency Graph
[Text representation of key dependencies]

## Next Steps
1. Review task list
2. Adjust priorities if needed
3. Begin implementation with `task_get_next`
```

### Step 9: Present Summary

After creating all tasks:

```
Roadmap generated from product documents

Created [N] tasks:
- Infrastructure: [count]
- Core: [count]
- Features: [count]
- Enhancement: [count]

Total estimated effort: [sum]

Roadmap overview saved to: .bot/workspace/product/roadmap-overview.md

Ready to begin implementation!
Use task_get_next to get the first task.
```

## Task Schema Reference

Each task created via `task_create_bulk` must include:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Brief, action-oriented title |
| `description` | Yes | Detailed description including what, where, why |
| `category` | Yes | infrastructure/core/feature/enhancement/ui-ux/bugfix |
| `priority` | Yes | 1-100 (1 = highest) |
| `effort` | Yes | XS/S/M/L/XL |
| `dependencies` | No | Array of task IDs this depends on |
| `acceptance_criteria` | Yes | Array of testable success conditions |
| `steps` | No | Implementation steps for guidance |
| `applicable_standards` | No | Standards files to read before implementing |
| `applicable_agents` | No | Agent files to use for implementation |

## Task Writing Guidelines

### Good Task Names
- Action verb + specific component
- "Implement [X] command handler"
- "Create [X] background job"
- "Add [X] entity with migrations"
- "Configure [X] integration"

### Good Descriptions
Include:
- **What**: Specific component or feature
- **Where**: Which project/namespace
- **Why**: Context from product docs/mission
- **How**: Key technical requirements from tech-stack.md
- **Patterns**: Reference existing patterns to follow

### Good Acceptance Criteria
- Specific and testable
- Each starts with a verb
- Covers happy path and key edge cases
- Includes test requirements where appropriate

## Error Handling

- If MCP tools fail, report the error and allow retry
- If a task batch partially succeeds, report which tasks were created
- Save roadmap overview even if some tasks fail
- Provide manual task creation instructions as fallback

## Success Criteria

- All product documents read and analyzed
- All features from product docs represented as tasks
- Tasks properly categorized and prioritized
- Dependencies correctly mapped
- Tasks created in `.bot/workspace/tasks/todo/` via MCP
- No duplicate tasks
- Roadmap overview generated
- Summary reported
