# Plan Product Command

Create a comprehensive product plan including mission, roadmap, and tech stack.

## Description

This command guides you through planning a new product or major initiative by creating:
- **Product Mission**: Clear vision and purpose
- **Product Roadmap**: Phased feature development plan
- **Tech Stack**: Technology choices and rationale

## When to Use

Use this command when you:
- Are starting a new product or project
- Need to align team on product vision
- Want to plan feature priorities
- Need to document tech stack decisions
- Are pivoting or refocusing an existing product

## Process

### Phase 1: Gather Product Concept

Understand and document:
- **Vision**: What problem does this solve?
- **Target Users**: Who is this for?
- **Key Features**: What capabilities are essential?
- **Success Metrics**: How do you measure success?
- **Constraints**: Budget, timeline, technical limitations

### Phase 2: Create Mission Document

Write a concise mission document that includes:

```markdown
# [Product Name] Mission

## Vision
[1-2 sentence vision statement]

## Problem Statement
[What problem are we solving and for whom?]

## Target Users
- Primary: [User persona 1]
- Secondary: [User persona 2]

## Core Value Proposition
[Why would users choose this over alternatives?]

## Success Criteria
- [Metric 1]
- [Metric 2]
- [Metric 3]
```

### Phase 3: Create Roadmap

Build a phased development plan:

```markdown
# [Product Name] Roadmap

## Phase 1: MVP (Month 1-2)
**Goal**: Validate core concept with early users

**Features:**
- [ ] Feature A (essential)
- [ ] Feature B (essential)
- [ ] Feature C (essential)

**Success Metrics:**
- [Metric to validate MVP]

## Phase 2: Growth (Month 3-6)
**Goal**: Scale and improve based on feedback

**Features:**
- [ ] Feature D (high value)
- [ ] Feature E (high value)
- [ ] Improvements from MVP feedback

**Success Metrics:**
- [Growth metrics]

## Phase 3: Maturity (Month 6+)
**Goal**: Polish and expand

**Features:**
- [ ] Advanced features
- [ ] Integrations
- [ ] Performance optimization
```

### Phase 4: Define Tech Stack

Document technology choices:

```markdown
# [Product Name] Tech Stack

## Frontend
- **Framework**: [Choice and why]
- **State Management**: [Choice and why]
- **Styling**: [Choice and why]

## Backend
- **Language/Runtime**: [Choice and why]
- **Framework**: [Choice and why]
- **Database**: [Choice and why]

## Infrastructure
- **Hosting**: [Choice and why]
- **CI/CD**: [Choice and why]
- **Monitoring**: [Choice and why]

## Rationale
[Explain key tech decisions and trade-offs]
```

## Output

Three documents in your product planning folder:

1. **mission.md** - Product vision and purpose
2. **roadmap.md** - Phased feature plan
3. **tech-stack.md** - Technology choices with rationale

## Standards

This command follows:
- `.bot/standards/global/coding-style.md`
- `.bot/standards/global/error-handling.md`

## Workflow

This command follows:
- `.bot/workflows/planning/` (when created)

## How to Use

In Warp AI, press **Ctrl-Shift-R** and select:
```
dotbot-1-gather-product-info
```

This starts the planning workflow which will:
- Ask clarifying questions about users, features, constraints
- Create mission document with vision and value prop
- Build 3-phase roadmap with prioritized features
- Document tech stack choices with rationale

## Tips

- Keep mission focused and clear
- Prioritize ruthlessly in roadmap
- Start with proven, stable tech
- Document "why" for major decisions
- Revisit and update as you learn
- Share documents with whole team
- Use roadmap to say "no" to scope creep

