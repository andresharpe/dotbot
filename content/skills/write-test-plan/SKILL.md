---
name: write-test-plan
description: Generate a QA/UAT test plan from product specifications and task definitions, covering acceptance testing, integration flows, and exploratory testing. Unit tests are out of scope (handled by write-unit-tests skill).
auto_invoke: false
---

# Write Test Plan

Guide for producing a QA/UAT test plan that maps every acceptance criterion and feature scope item to verifiable test scenarios at the integration, acceptance, and exploratory levels.

## Prerequisites

Both of these must exist before writing a test plan:

1. **Product specifications** — at least one of: `mission.md`, `entity-model.md`, PRD, change request, or interview summary
2. **Task definitions** — task list with acceptance criteria (via `task_list` + `task_get` MCP calls, or `task-groups.json`)

If either is missing, stop and surface the gap to the operator. A test plan written without full scope is incomplete by definition.

## Inputs to Collect

```
.bot/workspace/product/mission.md              # core goals and principles
.bot/workspace/product/entity-model.md         # data model and relationships
.bot/workspace/product/tech-stack.md           # runtime, frameworks, E2E tooling
.bot/workspace/product/task-groups.json        # group-level scope and acceptance criteria
.bot/workspace/product/prd.md                  # if present
.bot/workspace/product/change-request-*.md     # if present (for change-scoped plans)
task_list (MCP)                                # all tasks with names, categories, criteria
```

Read every relevant file first, then call `task_list` to pull the live task queue. Do not write the plan until all inputs are loaded.

## Test Plan Structure

Output file: `.bot/workspace/product/test-plan.md`

### Required Sections

#### 1. Overview
- What this plan covers (product / feature / change request)
- Date and version
- Target audience: QA engineers, product owners, UAT participants
- Test approach summary

#### 2. Scope
- **In scope**: features, workflows, integrations, and user-facing behaviours covered
- **Out of scope**: unit/component-level testing (covered by write-unit-tests), explicitly excluded areas
- Derive both lists directly from `mission.md` and task group scopes — nothing implied

#### 3. Test Strategy

| Level | What is tested | Tooling | Who |
|-------|---------------|---------|-----|
| Integration | Multi-component flows, API contracts, DB state | (from tech-stack.md) | QA |
| E2E / Acceptance | Full user journeys from UI to persistence | (from tech-stack.md) | QA |
| UAT | Business scenarios validated against real requirements | Manual | Product owner / stakeholders |
| Exploratory | Edge cases, UX, error recovery, accessibility | Manual | QA |

Fill the tooling column from `tech-stack.md`. If no E2E tool is listed, mark that row as `Manual`.

#### 4. Test Scenarios

For each **task group** (and for significant individual tasks), produce a scenario block:

```
### [Group Name] — [group id]

**Acceptance criteria covered:**
- [ ] <criterion from task or group>

**Integration scenarios:**
| ID | Scenario | Setup | Expected outcome |
|----|----------|-------|-----------------|
| I-01 | ... | ... | ... |

**E2E / Acceptance scenarios:**
| ID | Scenario | Steps | Pass condition |
|----|----------|-------|---------------|
| E-01 | ... | ... | ... |

**UAT scenarios:**
| ID | Business scenario | Actor | Pass condition |
|----|------------------|-------|---------------|
| UAT-01 | ... | ... | ... |

**Exploratory notes:**
- Areas to probe manually: <list edge cases, error paths, UX concerns>
```

Rules:
- Every acceptance criterion from every task must map to at least one scenario ID
- Scenario IDs are globally unique (I-01…I-nn, E-01…E-nn, UAT-01…UAT-nn)
- Integration scenarios: specify what's real vs. stubbed (e.g., "real DB, stubbed email service")
- E2E scenarios: written as observable user steps with a clear pass/fail condition
- UAT scenarios: written in business language, not technical terms — stakeholders must be able to run them without developer help
- Exploratory notes: list areas QA should probe freely, not scripted steps

#### 5. Risk Areas

List areas where coverage is hardest or most critical:
- Complex business rules with many conditional paths
- External integrations and third-party APIs
- Async / background processes (jobs, notifications, webhooks)
- Security-sensitive paths (auth, authorisation, data visibility)
- Data migrations or schema changes visible to users

For each risk, note the mitigation (extra E2E coverage, manual regression gate, contract tests, etc.).

#### 6. Test Data Requirements

- User accounts and roles needed for UAT
- Seed data for integration and E2E scenarios
- External service stubs, recordings, or sandbox credentials
- Environment variables or feature flags required for test runs
- Any data privacy constraints (no real PII in test environments)

#### 7. Entry and Exit Criteria

**Entry** (test execution can begin when):
- [ ] All tasks in the group are marked `done`
- [ ] Deployment to test environment is complete
- [ ] Test data is seeded
- [ ] Unit tests pass (prerequisite, not this plan's responsibility)

**Exit** (group is considered QA-complete when):
- [ ] All integration scenarios pass
- [ ] All E2E / acceptance scenarios pass
- [ ] All UAT scenarios signed off by product owner
- [ ] No open critical or high-severity defects
- [ ] No acceptance criterion is unmapped

## Derivation Rules

### From acceptance criteria → test scenarios
Each criterion becomes ≥1 integration or E2E scenario. Criteria describing user-visible behaviour also need a UAT scenario written in plain business language.

### From entity model → integration scenarios
Every entity relationship with a constraint (FK, unique, cascade delete) needs at least one integration scenario that validates the constraint is enforced end-to-end, not just at the unit level.

### From tech stack → tooling column
Read the testing section of `tech-stack.md`. If it lists an E2E framework (e.g., Playwright, Cypress, Selenium), use it in the strategy table. If none is listed, write `Manual`.

### From risk areas → coverage weighting
High-risk areas get additional exploratory notes and explicit regression scenarios. Call this out in the Risk Areas section.

## Output Checklist

- [ ] All task acceptance criteria are mapped to at least one scenario ID
- [ ] All task groups have a scenario block
- [ ] Scope section lists both in-scope and out-of-scope items
- [ ] Strategy table has tooling filled from tech-stack
- [ ] UAT scenarios are written in plain business language (no code references)
- [ ] Risk areas section is populated
- [ ] Test data requirements are listed
- [ ] Entry and exit criteria are defined
- [ ] Scenario IDs are globally unique and sequential
- [ ] No absolute local paths in the document
- [ ] No secrets, tokens, or real PII in test data examples
