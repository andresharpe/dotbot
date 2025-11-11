# Write Specification Command

Write a detailed technical specification for a feature or component.

## Description

This command helps you create a comprehensive specification document that includes:
- Feature overview and goals
- User stories and acceptance criteria  
- Technical design (architecture, data models, APIs)
- Implementation plan with task breakdown
- Testing strategy
- Risk analysis

## When to Use

Use this command when you need to:
- Design a new feature before implementation
- Document technical decisions and architecture
- Create a shared understanding across the team
- Plan implementation work and estimates
- Establish acceptance criteria for a feature

## Inputs

You should provide:
- **Feature Description**: What you want to build
- **Requirements**: Functional and non-functional requirements
- **Constraints**: Technical limitations, dependencies, timeline
- **Context**: Related features, existing architecture

## Standards

This command follows these standards:
- `.bot/standards/global/coding-style.md`
- `.bot/standards/global/error-handling.md`

## Workflow

This command follows the workflow:
- `.bot/workflows/specification/write-spec.md`

## Output

A markdown specification document that includes:

1. **Overview**: Clear description of the feature
2. **Goals**: What success looks like
3. **Non-Goals**: What's explicitly out of scope
4. **User Stories**: Who needs this and why
5. **Technical Design**: How it will be built
6. **Implementation Plan**: Phased approach with tasks
7. **Testing Strategy**: How to verify it works
8. **Risks**: What could go wrong and mitigations

## Example Usage

**User**: "Write a spec for user authentication with email and password"

**Agent**: [Creates a detailed spec covering OAuth flow, password hashing, session management, API endpoints, database schema, security considerations, etc.]

## Tips

- Be specific about what you want to build
- Provide context about existing systems
- Mention any technical constraints
- Specify if you prefer certain approaches
- Ask questions if anything is unclear

