# Shape Spec Command

Interactively shape and plan the scope for a new feature through guided conversation.

## Description

This command helps you explore and define a feature before writing a full specification. It's a collaborative process that:
- Clarifies the problem and solution approach
- Establishes scope boundaries (what's in, what's out)
- Explores design approaches and trade-offs
- Creates a lightweight spec document

## When to Use

Use this command when you:
- Have a feature idea but need to flesh out details
- Want to explore solution approaches before committing
- Need to clarify scope and boundaries
- Want a lightweight spec before full specification
- Are in the early exploration phase

## Process

### Phase 1: Initialize Spec

Create a basic spec document structure:

```markdown
# [Feature Name] - Spec (Draft)

## Problem
[What problem are we solving?]

## Proposed Solution
[High-level approach]

## Scope
### In Scope
- [What we'll include]

### Out of Scope
- [What we won't include]

## Open Questions
- [Questions to resolve]

## Design Decisions
[Key decisions and rationale]
```

### Phase 2: Shape the Spec

Work through these questions interactively:

#### Understanding the Problem
- What problem are we solving?
- Who has this problem?
- How do they currently solve it?
- Why is the current solution insufficient?

#### Exploring Solutions
- What's the simplest solution?
- What are alternative approaches?
- What are the trade-offs?
- What's the riskiest assumption?

#### Defining Scope
- What's the core value?
- What can we defer?
- What dependencies exist?
- What's explicitly out of scope?

#### Design Considerations
- What are the key technical decisions?
- What's the user experience?
- What's the data model?
- What are the integration points?

### Phase 3: Document Decisions

Capture:
- **Key Decisions**: What was decided and why
- **Trade-offs**: What was sacrificed for what benefit
- **Open Questions**: What needs more investigation
- **Next Steps**: What comes after this shaping phase

## Output

A shaped spec document that includes:
- Clear problem statement
- Proposed solution approach
- Defined scope boundaries
- Key design decisions documented
- Open questions identified
- Path forward established

This document serves as input for:
- Full specification writing (`write-spec` command)
- Task breakdown (`create-tasks` command)
- Team alignment discussions

## Standards

This command follows:
- `.bot/standards/global/coding-style.md`
- `.bot/standards/global/error-handling.md`

## Workflow

This command follows:
- `.bot/workflows/specification/write-spec.md` (adapted for shaping)

## Example Usage

**User**: "I want to add a comment system to our blog"

**Agent**: 
- Asks: What should users be able to do with comments?
- Asks: Should comments be nested/threaded?
- Asks: What about moderation, editing, spam?
- Creates shaped spec with clear scope
- Documents decisions: flat comments only, no editing after 5 min, etc.

## Tips

- Start broad, then narrow
- Ask "why" to understand true needs
- Push back on scope creep
- Document trade-offs explicitly
- Identify riskiest unknowns
- Keep it lightweight - full spec comes later
- Use this to align stakeholders early

