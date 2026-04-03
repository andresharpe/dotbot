# Workflow Prompts

This directory contains workflow prompts that guide AI agents through specific processes. Each workflow is a self-contained document that provides step-by-step instructions for completing a particular type of work.

## Numbering Convention

| Range | Purpose | Survives profile overlay? |
|-------|---------|---------------------------|
| 00-89 | Profile-specific workflow steps | No — cleared when a workflow profile is installed |
| 90-97 | Universal utilities (commit, tasks, steering) | Yes |
| 98-99 | Core execution (analyse, autonomous) | Yes |

When a workflow-type profile (e.g., `kickstart-via-jira`) is installed via `dotbot init`, any default workflow files in the 00-89 range that are **not** provided by the overlay profile are automatically removed. Files numbered 90+ are preserved across all profiles.

## Available Workflows

### Profile-Specific (00-89)

#### 01-plan-product.md
**Purpose**: Create or refine product plans and roadmaps

**When to use**:
- Defining product vision and goals
- Planning feature sets and priorities
- Creating product documentation

#### 03-plan-roadmap.md
**Purpose**: Develop implementation roadmaps from product plans

**When to use**:
- Breaking down product plans into implementable tasks
- Sequencing work and identifying dependencies
- Creating development timelines

#### 05-retrospective-task.md
**Purpose**: Document completed work retrospectively

**When to use**:
- Creating historical records of past implementations
- Backfilling documentation for work completed outside tracked sessions
- Documenting work done before task tracking was in place

**Key features**:
- Guided task JSON creation with sample templates
- Plan markdown structure with section guidance
- File naming and path conventions
- Validation checklist

**Outputs**:
- Task JSON: `.bot/workspace/tasks/done/{task-name}-{task-id}.json`
- Plan markdown: `.bot/workspace/plans/{task-name}-{task-id}-plan.md`

### Universal Utilities (90-97)

#### 90-commit-and-push.md
**Purpose**: Organize changes into logical commits and push

**When to use**:
- Multiple uncommitted changes to organize
- Changes span different topics
- Maintaining clean git history

**Key features**:
- Topic grouping guidance
- Conventional commit format (feat/fix/docs/etc.)
- Split vs combine decisions
- Quick reference for git operations

#### 91-new-tasks.md
**Purpose**: Generate new tasks from plans or requirements

**When to use**:
- Converting plan sections into actionable tasks
- Creating TODO lists for development work
- Defining task acceptance criteria

#### 92-steering-protocol.include.md
**Purpose**: Steering protocol included in autonomous workflows to allow operator interrupts

### Core Execution (98-99)

#### 98-analyse-task.md
**Purpose**: Pre-flight analysis — explore codebase, identify affected files, build context

#### 99-autonomous-task.md
**Purpose**: Complete development tasks autonomously in "Go Mode"

**When to use**:
- Implementing features or fixes with minimal supervision
- Following a predefined plan
- Autonomous coding sessions

**Key features**:
- Full task execution protocol
- MCP tool integration
- Verification scripts
- Problem logging
- Git commit conventions

## How to Use Workflows

### Option 1: Direct Prompt (Simplest)
Copy the workflow content and paste it into your Claude chat:

```
Hey Claude, [paste workflow content here]

Additional context:
- [Your specific information]
```

### Option 2: File Reference
If you have file access enabled, reference the workflow file:

```
Claude, read and follow the workflow at:
.bot/recipes/prompts/05-retrospective-task.md

Work to document:
- [Your specific information]
```

## Workflow Structure

All workflows follow a consistent structure:

1. **Front Matter** (YAML)
   - name: Workflow name
   - description: Brief purpose
   - version: Version number

2. **Purpose/Overview**
   - What the workflow is for
   - When to use it

3. **Prerequisites/Required Information**
   - What you need before starting
   - Information to gather

4. **Implementation Protocol**
   - Step-by-step instructions
   - Tool usage guidance
   - Examples

5. **Validation/Success Criteria**
   - How to verify completion
   - Quality standards

## Creating New Workflows

When creating a new workflow:

1. Follow the existing structure pattern
2. Include front matter with metadata
3. Provide clear step-by-step instructions
4. Include examples where helpful
5. Add validation checklists
6. Update this README with the new workflow

## Sample Templates

Sample templates are available in `.bot/workspace/tasks/samples/`:

- `sample-task-retrospective.json` - Task JSON structure with explanatory comments
- `sample-plan-retrospective.md` - Plan markdown structure with section guidance

These samples are used by the retrospective workflow to guide documentation creation.

## Related Documentation

- **Agents**: `.bot/recipes/agents/` - Persona definitions for different work modes
- **Skills**: `.bot/recipes/skills/` - Technical guidance for specific patterns
- **Standards**: `.bot/standards/` - Coding standards and conventions
