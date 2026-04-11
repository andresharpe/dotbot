# Triage Playbook

Internal guide for the advisory-steering group. This is how we turn raw issues into well-defined, ready-to-build work items.

## Triage cadence

Twice weekly: **Tuesday and Friday**, discussed in `#advisory-steering` on Discord.

Each session should take 15-30 minutes. Work through the `needs-triage` queue on the [project board](https://github.com/users/andresharpe/projects/2) (use the "Triage queue" saved view).

## Decision tree

For each issue in `needs-triage`, pick one:

1. **Close** - not something we'll do. Apply `wontfix` or `duplicate`, leave a brief reason, close.
2. **Needs info** - can't triage without more detail. Apply `needs-info`, comment with what's missing, leave in Triage.
3. **Spec/Design** - the problem is valid but needs a PRD or design before it's buildable. Move to Spec/Design, assign someone to write the PRD.
4. **Ready** - problem is clear, acceptance criteria are obvious, small enough to build without a PRD. Move to Ready.

## Definition of Ready

Before an issue moves to Ready, confirm:

- [ ] Problem statement is clear - anyone on the team can understand what needs to change
- [ ] Acceptance criteria are written (inline in the issue or linked PRD)
- [ ] PRD or design linked if the change is non-trivial
- [ ] Size estimated (XS/S/M/L/XL label applied)
- [ ] No owner assigned - leave it open so any contributor can self-assign from the Ready pile

## Writing a one-page PRD inline

For issues that need more definition but don't warrant a separate document, add a PRD section directly in the issue body:

```markdown
## PRD

### Problem
What is broken or missing, and who is affected.

### Proposed solution
What we will build. Be specific about behaviour, not implementation.

### Acceptance criteria
- [ ] Criterion 1
- [ ] Criterion 2

### Out of scope
What this does NOT cover.

### Open questions
Anything unresolved that might change the approach.
```

For bigger architectural decisions, discuss in `#decisions-adrs` on Discord and record the decision as an ADR in the repo (create a `docs/adr/` folder when the first one is needed).

## Escalation

If the steering group is unavailable (holidays, conflicting priorities):

1. Andre (@andresharpe) can triage solo for up to two weeks.
2. If Andre is also unavailable, any core product team member can apply `ready` with a comment explaining the rationale.
3. Controversial or large items should wait for the full group.

## Automation

These things happen automatically:

- New issues get `needs-triage` label via issue templates
- Issues untriaged for 2+ days trigger a nudge in `#advisory-steering` (weekday mornings)
- Issues in `ready` untouched for 60 days get marked `stale` and closed after 14 more days
- Issues in `needs-triage` untouched for 30 days get a ping comment
- A weekly stale digest posts to `#advisory-steering` every Monday
