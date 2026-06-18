# SAMPLE PLAN FOR RETROSPECTIVE DOCUMENTATION

**Instructions**: Copy this template, fill in each section, save to `.bot/workspace/plans/{task-name}-{task-id}-plan.md`

---

# Problem Statement

_Describe the problem or need that was addressed._

What was the issue? Why did it need to be solved? What was the impact of not solving it?

Example:
> The application had authentication errors when jobs ran without valid tokens. This caused error logs instead of graceful warnings.

---

# Current State

_Document the state of the system before the work was done._

## What existed

- List existing components, files, or patterns
- Describe the behavior that needed to change
- Note any constraints or limitations

## Issues/Gaps

- What wasn't working?
- What was missing?
- What technical debt existed?

---

# Proposed Solution

_Describe the approach taken to solve the problem._

## High-Level Approach

Summarize the solution strategy in 2-3 sentences.

## Key Components

Break down the major pieces:

1. **Component 1**: What it does and why
2. **Component 2**: What it does and why
3. **Component 3**: What it does and why

## Design Decisions

Document important choices made:

- **Decision**: Why this approach vs alternatives?
- **Trade-offs**: What was gained/lost?
- **Rationale**: Why was this the right choice?

---

# Implementation Steps

_The sequence of work that was done._

## Phase 1: [Phase Name]

1. Step 1 description
2. Step 2 description
3. Step 3 description

## Phase 2: [Phase Name]

1. Step 1 description
2. Step 2 description

## Phase 3: [Phase Name]

1. Step 1 description
2. Step 2 description

---

# Files Modified/Created

_OPTIONAL: Can list key files if helpful for context._

## New Files

- `path/to/new/file.cs` - Purpose/description

## Modified Files

- `path/to/modified/file.cs` - What changed and why

---

# Testing/Verification

_How the work was validated._

- Unit tests added/modified
- Integration tests run
- Manual verification steps
- Linting/type checking

---

# Success Criteria

_How success was measured._

- [ ] Criterion 1: Specific measurable outcome
- [ ] Criterion 2: Another measurable outcome
- [ ] Criterion 3: Final validation

---

# Notes/Learnings

_OPTIONAL: Any insights, gotchas, or future considerations._

- Thing learned during implementation
- Potential future improvements
- Related work that could build on this
