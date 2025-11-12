# Verify Implementation Workflow

**Agent:** @.bot/agents/implementation-verifier.md

This workflow ensures that implemented code meets quality, correctness, and standards requirements.

## Purpose

Verification catches issues early and ensures:
- Code works as specified
- Tests pass and cover requirements
- Standards are followed
- Quality is maintained
- Nothing is broken

## When to Use

Use this workflow:
- After implementing tasks
- Before marking tasks complete
- Before code review
- Before merging changes

## Verification Checklist

### 1. Correctness Verification

**Functional Requirements:**
- [ ] All acceptance criteria met
- [ ] Feature works as specified
- [ ] Edge cases handled
- [ ] Error scenarios handled properly

**Manual Testing:**
- [ ] Happy path works
- [ ] Error paths work
- [ ] UI/UX is correct (if applicable)
- [ ] Data flow is correct

### 2. Test Coverage Verification

**Unit Tests:**
- [ ] All new code has unit tests
- [ ] Tests cover happy paths
- [ ] Tests cover edge cases
- [ ] Tests cover error conditions
- [ ] All tests pass

**Integration Tests:**
- [ ] Integration points tested (if applicable)
- [ ] API contracts verified
- [ ] Database interactions tested
- [ ] Third-party integrations tested

**Test Quality:**
- [ ] Tests are clear and maintainable
- [ ] Tests don't have false positives
- [ ] Test names describe what they test
- [ ] Tests are deterministic

### 3. Standards Compliance

**Coding Standards:**
- [ ] Follows coding style standard
- [ ] Naming conventions followed
- [ ] Code is DRY (not duplicated)
- [ ] Functions are focused and small

**Error Handling:**
- [ ] Errors are caught appropriately
- [ ] Error messages are helpful
- [ ] Failures are logged
- [ ] Recovery mechanisms exist

**Validation:**
- [ ] Input validation present
- [ ] Server-side validation implemented
- [ ] Business rules validated
- [ ] Data integrity maintained

**Commenting:**
- [ ] Complex logic explained
- [ ] API documentation present
- [ ] No outdated comments
- [ ] No commented-out code

### 4. Code Quality Verification

**Cleanliness:**
- [ ] No debug code (console.logs, debugger statements)
- [ ] No hardcoded values
- [ ] No magic numbers
- [ ] No dead code

**Performance:**
- [ ] No obvious performance issues
- [ ] Database queries optimized
- [ ] No N+1 query problems
- [ ] Resource cleanup implemented

**Security:**
- [ ] No security vulnerabilities
- [ ] Input sanitized
- [ ] Authentication/authorization correct
- [ ] Sensitive data handled properly

### 5. Documentation Verification

**Code Documentation:**
- [ ] Public APIs documented
- [ ] Complex logic explained
- [ ] Configuration documented

**Project Documentation:**
- [ ] README updated if needed
- [ ] CHANGELOG updated if applicable
- [ ] Migration guides added if needed
- [ ] API docs updated if applicable

### 6. Integration Verification

**No Breaking Changes:**
- [ ] Existing tests still pass
- [ ] No regressions introduced
- [ ] Backward compatibility maintained (if required)
- [ ] APIs are versioned if changed

**Dependencies:**
- [ ] Required tasks completed first
- [ ] Integration points work
- [ ] No circular dependencies

### 7. Completion Verification

**Task Tracking:**
- [ ] Tasks checked off in tasks.md
- [ ] Implementation notes added
- [ ] Follow-up tasks noted

**Version Control:**
- [ ] Changes committed
- [ ] Commit messages clear
- [ ] Branch up to date
- [ ] Ready for review/merge

## Verification Process

1. **Run all tests**
   - Execute full test suite
   - Verify all tests pass
   - Check test coverage metrics

2. **Run linter/formatter**
   - Execute linting tools
   - Fix all issues
   - Verify code style compliance

3. **Manual verification**
   - Test feature manually
   - Verify in browser/app (if applicable)
   - Check error scenarios
   - Verify edge cases

4. **Code review checklist**
   - Self-review code
   - Check against standards
   - Verify documentation
   - Confirm quality

5. **Final checks**
   - Update task list
   - Update documentation
   - Commit changes
   - Prepare for review

## Red Flags

Stop and fix if you see:
- ❌ Tests failing
- ❌ Linting errors
- ❌ Console errors
- ❌ Broken functionality
- ❌ Missing error handling
- ❌ Security issues
- ❌ Performance problems
- ❌ Incomplete implementation

## Output

A verified implementation with:
- ✅ All tests passing
- ✅ Standards followed
- ✅ Quality maintained
- ✅ Documentation updated
- ✅ Ready for review/deployment

## Tips

- Don't skip verification to move faster
- Use automated tools where possible
- Test edge cases thoroughly
- Get fresh eyes on complex changes
- Document any trade-offs made
- Fix issues immediately, don't defer

