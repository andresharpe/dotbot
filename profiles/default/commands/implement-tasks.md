# Implement Tasks Command

Implement features by working through a tasks list with proper verification.

## Description

This command guides you through implementing tasks from a tasks.md file. It ensures:
- Tasks are understood before implementation
- Code follows standards
- Tests are written
- Implementation is verified
- Progress is tracked

## When to Use

Use this command when you:
- Have a tasks.md file ready to implement
- Want structured guidance through implementation
- Need to ensure quality and standards compliance
- Want built-in verification steps

## Prerequisites

- Completed specification (spec.md)
- Task breakdown (tasks.md)
- Development environment set up
- Standards documented

## Process

### Step 1: Determine Tasks

If you don't already know which tasks to implement:
1. Ask user which spec/tasks file to work from
2. List available task groups
3. Confirm which tasks to implement

### Step 2: Implement Each Task

For each task in the tasks list:

#### A. Understand the Task
- Read the task description
- Review acceptance criteria
- Check the related spec section
- Identify dependencies
- Review relevant standards

#### B. Write Tests (TDD Approach)
- Write failing tests for expected behavior
- Cover happy path scenarios
- Cover edge cases
- Cover error conditions
- Follow testing standards

#### C. Implement the Solution
- Follow coding standards
- Keep code clean and simple
- Handle errors appropriately
- Add meaningful comments where needed
- Follow existing patterns in codebase

#### D. Make Tests Pass
- Run tests frequently
- Fix issues as they arise
- Refactor for clarity
- Ensure all tests pass

#### E. Manual Verification
- Test the feature manually
- Verify UI/UX if applicable
- Check edge cases
- Ensure it works in real scenarios

#### F. Self Code Review
- Check against coding standards
- Ensure no debug code remains
- Verify error handling
- Check for performance issues
- Confirm documentation is updated

### Step 3: Verify Implementation

Before marking task complete, verify:

✓ **Matches Spec**
- Implementation matches requirements
- Acceptance criteria are met
- No scope creep

✓ **Follows Standards**
- Coding style standards followed
- Error handling standards followed
- Validation standards followed
- Commenting standards followed

✓ **Test Coverage**
- Unit tests written and passing
- Integration tests if needed
- Edge cases covered
- Error scenarios tested

✓ **Quality Checks**
- Code is clean and maintainable
- No code smells
- Follows DRY principle
- Consistent with codebase

✓ **Documentation**
- Code comments where needed
- API docs updated
- README updated if needed
- CHANGELOG updated if applicable

### Step 4: Mark Task Complete

- Check off the task in tasks.md
- Update any related documentation
- Note any follow-up tasks
- Commit changes with clear message

## Output

For each implemented task:
- ✅ Working, tested code
- ✅ Tests passing
- ✅ Documentation updated
- ✅ Task checked off in tasks.md
- ✅ Quality verified
- ✅ Standards followed

## Standards

This command follows:
- `dotbot/standards/global/coding-style.md`
- `dotbot/standards/global/error-handling.md`
- `dotbot/standards/global/validation.md`
- `dotbot/standards/global/commenting.md`
- `dotbot/standards/global/conventions.md`
- Any project-specific standards

## Workflow

This command follows:
- `dotbot/workflows/implementation/implement-tasks.md`

## Best Practices

**Work Incrementally**
- Implement one task at a time
- Commit frequently
- Test as you go

**Maintain Quality**
- Don't skip tests
- Don't ignore linting errors
- Don't compromise standards

**Communicate**
- Ask questions when unclear
- Flag blockers early
- Update task status regularly

**Handle Blockers**
- Document the blocker
- Try workarounds
- Work on other tasks if blocked
- Communicate to team

## Example Usage

**User**: "Implement the authentication tasks"

**Agent**:
1. Reads authentication task group from tasks.md
2. Implements user registration with tests
3. Implements login with tests
4. Implements password reset
5. Verifies all acceptance criteria met
6. Checks off tasks as completed

## Tips

- Read the full spec before starting
- Understand acceptance criteria clearly
- Write tests before implementation
- Keep commits small and focused
- Refactor as you go
- Don't accumulate technical debt
- Ask for clarification early
- Document decisions and trade-offs
