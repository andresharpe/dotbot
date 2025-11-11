# Implement Tasks Workflow

This workflow guides you through implementing features based on specifications.

## Prerequisites

- Completed specification document
- Tasks broken down and prioritized
- Development environment set up
- Standards and conventions understood

## Steps

### 1. Review the Specification

Before starting implementation:
- Read the entire spec thoroughly
- Understand the goals and non-goals
- Clarify any ambiguities
- Identify dependencies

### 2. Set Up Task Tracking

Create or update your task list:
- Break spec into implementable tasks
- Prioritize by dependencies and impact
- Estimate effort for each task
- Assign to team members (if applicable)

### 3. Implement Task by Task

For each task:

#### a. Understand Requirements
- Review the specific requirements for this task
- Check related standards
- Understand how it fits into the overall feature

#### b. Write Tests First (TDD)
- Write failing tests that define expected behavior
- Cover edge cases and error conditions
- Follow testing standards

#### c. Implement Solution
- Follow coding standards
- Keep functions small and focused
- Add meaningful comments where needed
- Handle errors appropriately

#### d. Make Tests Pass
- Run tests frequently
- Fix issues as they arise
- Refactor for clarity and maintainability

#### e. Manual Testing
- Test the feature manually
- Verify it works in real scenarios
- Check for usability issues

### 4. Code Review

Before marking a task complete:
- Self-review your code
- Check against standards
- Ensure tests are comprehensive
- Document any deviations from spec

### 5. Address Feedback

If you're working with a team:
- Submit for code review
- Address review comments
- Explain decisions if needed
- Re-test after making changes

### 6. Verify Implementation

Ensure the implementation:
- ✓ Matches the spec
- ✓ Follows coding standards
- ✓ Has adequate test coverage
- ✓ Handles errors properly
- ✓ Performs acceptably
- ✓ Is documented

### 7. Update Documentation

- Update inline documentation
- Update API docs if applicable
- Update README or user guides
- Add migration guides if needed

### 8. Mark Task Complete

Once verified:
- Mark task as complete in your tracker
- Update the spec if anything changed
- Note any follow-up tasks
- Communicate completion to team

## Best Practices

### Stay Focused
- Work on one task at a time
- Finish tasks before starting new ones
- Avoid scope creep

### Commit Frequently
- Make small, logical commits
- Write clear commit messages
- Reference related tasks/issues

### Communicate
- Update task status regularly
- Flag blockers immediately
- Ask questions early
- Share progress with team

### Maintain Quality
- Don't skip tests
- Don't ignore linting errors
- Don't rush reviews
- Don't compromise on standards

### Handle Blockers
If you get blocked:
1. Document the blocker
2. Try to find a workaround
3. Communicate to the team
4. Work on a different task if possible

### Refactor as You Go
- Keep code clean as you build
- Don't accumulate technical debt
- Refactor when you see opportunities
- Maintain consistent patterns

## Output

For each task:
- ✓ Working, tested code
- ✓ Tests passing
- ✓ Documentation updated
- ✓ Code reviewed (if applicable)
- ✓ Ready for integration

## Common Pitfalls

❌ **Starting without understanding the spec**
✓ Always review the spec first

❌ **Skipping tests to move faster**
✓ Tests save time in the long run

❌ **Not following standards**
✓ Consistency is more important than speed

❌ **Trying to do too much at once**
✓ Break work into smaller pieces

❌ **Not asking for help when stuck**
✓ Ask questions early and often

