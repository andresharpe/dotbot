# Create Tasks Command

Break down a specification into implementable tasks with clear acceptance criteria.

## Description

This command helps you:
- Analyze a specification document
- Break it into logical task groups
- Create individual tasks with sub-tasks
- Define acceptance criteria for each task
- Estimate effort and identify dependencies

## When to Use

Use this command when you:
- Have a completed specification ready for implementation
- Need to break down a large feature into manageable pieces
- Want to plan implementation phases
- Need to estimate development effort
- Want to create a task tracking structure

## Inputs

You should provide:
- **Spec Document**: Path to your specification markdown file
- **Priority**: Which features/areas should be implemented first
- **Constraints**: Team size, timeline, dependencies

## Process

### 1. Review the Specification

Read and understand:
- Feature overview and goals
- Technical design and architecture
- Implementation plan (if included)
- Testing requirements

### 2. Identify Task Groups

Group related work into logical units:
- By feature area (e.g., "Authentication", "User Dashboard")
- By layer (e.g., "Database", "API", "Frontend")
- By phase (e.g., "MVP", "Polish", "Optimization")

### 3. Break Down Tasks

For each task group, create specific tasks:
- Clear, actionable task descriptions
- Acceptance criteria (what "done" looks like)
- Sub-tasks for complex work
- Dependencies on other tasks

### 4. Estimate Effort

For each task:
- Estimate complexity (S/M/L or hours)
- Identify unknowns or risks
- Note dependencies

### 5. Create tasks.md

Generate a structured tasks document:

```markdown
# Tasks: [Feature Name]

## Task Group: [Group Name]

### Task 1: [Task Title]
**Acceptance Criteria:**
- [ ] Criterion 1
- [ ] Criterion 2

**Sub-tasks:**
- [ ] Sub-task A
- [ ] Sub-task B

**Estimate:** [S/M/L]
**Dependencies:** [Other tasks]

### Task 2: [Task Title]
[Repeat structure]

## Task Group: [Next Group]
[Repeat structure]
```

## Output

A `tasks.md` file containing:
- Organized task groups
- Clear task descriptions
- Acceptance criteria for each task
- Sub-tasks for complex work
- Effort estimates
- Dependency mapping
- Priority ordering

## Standards

This command follows:
- `dotbot/standards/global/coding-style.md`
- `dotbot/standards/global/error-handling.md`

## Workflow

This command follows:
- `dotbot/workflows/implementation/implement-tasks.md`

## Example Usage

**User**: "Create tasks from the user authentication spec"

**Agent**: [Analyzes spec, creates task groups for database schema, API endpoints, frontend UI, testing, etc., with detailed sub-tasks and acceptance criteria]

## Tips

- Keep tasks small enough to complete in 1-4 hours
- Make acceptance criteria testable and observable
- Group related tasks together
- Identify and note dependencies early
- Estimate conservatively
- Leave room for code review and testing
