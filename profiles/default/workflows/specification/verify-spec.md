# Spec Verification

**Agent:** @.bot/agents/spec-verifier.md

## Core Responsibilities

1. **Verify Requirements Accuracy**: Ensure user's answers are reflected in requirements.md
2. **Check Structural Integrity**: Verify all expected files and folders exist
3. **Analyze Visual Alignment**: If visuals exist, verify they're properly referenced
4. **Validate Reusability**: Check that existing code reuse is documented
5. **Verify Limited Testing Approach**: Ensure tasks follow focused, limited test writing (2-8 tests per task group)
6. **Document Findings**: Create verification report

## Workflow

### Step 1: Review Original Q&A

Review the questions that were asked to the user during requirements gathering and the user's raw responses to those questions.

### Step 2: Basic Structural Verification

#### Check 1: Requirements Accuracy
Read `.bot/specs/[this-spec]/planning/requirements.md` and verify:
- All user answers from the Q&A are accurately captured
- No answers are missing or misrepresented
- Any follow-up questions and answers are included
- Reusability opportunities are documented (paths or names of similar features)

#### Check 2: Visual Assets

Check for existence of any visual assets in the planning/visuals folder.

IF visuals exist, verify they're mentioned in requirements.md

### Step 3: Deep Content Validation

#### Check 3: Visual Asset Analysis (if visuals exist)
If visual files were found:
1. **Analyze each visual file** in `.bot/specs/[this-spec]/planning/visuals/`
2. **Document what you observe**: UI components, layouts, colors, typography, spacing
3. **Verify these design elements appear in**:
   - `.bot/specs/[this-spec]/spec.md` - Check if visual elements are specified
   - `.bot/specs/[this-spec]/tasks.md` - Confirm at least some tasks reference visual files or components shown in visuals

#### Check 4: Requirements Deep Dive
Read `.bot/specs/[this-spec]/planning/requirements.md` and note:
- **Explicit features requested**: What the user specifically said they want
- **Constraints stated**: Limitations, performance needs, or technical requirements
- **Out-of-scope items**: What the user explicitly said NOT to include
- **Reusability opportunities**: Names of similar features/paths the user provided

#### Check 5: Core Specification Validation
Read `.bot/specs/[this-spec]/spec.md` and verify each section:
1. **Goal**: Must directly address the problem stated in initial requirements
2. **User Stories**: The stories are relevant and aligned to the initial requirements
3. **Core Requirements**: Only include features from the requirements' explicit features
4. **Out of Scope**: Must match what the requirements state should not be included in scope
5. **Reusability Notes**: The spec mentions similar features to reuse (if user provided them)

Look for these issues:
- Added features not in requirements
- Missing features that were requested
- Changed scope from what was discussed
- Missing reusability opportunities (if user provided any)

#### Check 6: Task List Detailed Validation
Read `.bot/specs/[this-spec]/tasks.md` and check each task group's tasks:
1. **Test Writing Limits**: Verify test writing follows limited approach:
   - Each implementation task group (1-3) should specify writing 2-8 focused tests maximum
   - Test verification subtasks should run ONLY the newly written tests, not entire suite
   - If there's a testing task group, it should add maximum 10 additional tests
   - Flag if tasks call for comprehensive/exhaustive testing or running full test suite
2. **Reusability References**: Tasks should note "(reuse existing: [name])" where applicable
3. **Specificity**: Each task must reference a specific feature/component
4. **Traceability**: Each task must trace back to requirements
5. **Scope**: No tasks for features not in requirements
6. **Visual alignment**: Visual files (if they exist) must be referenced in at least some tasks
7. **Task count**: Should be 3-10 tasks per task group (flag if >10 or <3)

#### Check 7: Reusability and Over-Engineering Check
Review all specifications for:
1. **Unnecessary new components**: Are we creating new UI components when existing ones would work?
2. **Duplicated logic**: Are we recreating backend logic that already exists?
3. **Missing reuse opportunities**: Did we ignore similar features the user pointed out?
4. **Justification for new code**: Is there clear reasoning when not reusing existing code?

### Step 4: Document Findings and Issues

Create `.bot/specs/[this-spec]/verification/spec-verification.md` with findings structured as:

```markdown
# Specification Verification Report

## Verification Summary
- Overall Status: ✅ Passed / ⚠️ Issues Found / ❌ Failed
- Date: [Current date]
- Spec: [Spec name]
- Reusability Check: ✅ Passed / ⚠️ Concerns / ❌ Failed
- Test Writing Limits: ✅ Compliant / ⚠️ Partial / ❌ Excessive Testing

## Structural Verification (Checks 1-2)

### Check 1: Requirements Accuracy
[Document any discrepancies]

### Check 2: Visual Assets
[Document visual files found and verification]

## Content Validation (Checks 3-7)

### Check 3: Visual Design Tracking
[Only if visuals exist - list visual elements and their presence in specs/tasks]

### Check 4: Requirements Coverage
[List explicit features and their coverage status]

### Check 5: Core Specification Issues
[Document any alignment issues with requirements]

### Check 6: Task List Issues
[Document test writing limit compliance and other task issues]

### Check 7: Reusability and Over-Engineering
[Document unnecessary new components or duplicated logic]

## Critical Issues
[Issues that must be fixed before implementation]

## Minor Issues
[Issues that should be addressed but don't block progress]

## Over-Engineering Concerns
[Features/complexity added beyond requirements]

## Recommendations
[Specific recommendations to address issues]

## Conclusion
[Overall assessment: Ready for implementation? Needs revision? Major concerns?]
```

### Step 5: Output Summary

Output:

```
Specification verification complete!

✅ Verified requirements accuracy
✅ Checked structural integrity
✅ Validated specification alignment
✅ Verified test writing limits (2-8 tests per task group)
[If visuals] ✅ Analyzed [X] visual assets
⚠️ Reusability check: [Y issues found]

[If passed]
All specifications accurately reflect requirements, follow limited testing approach, and properly leverage existing code.

[If issues found]
⚠️ Found [X] issues requiring attention:
- [Number] reusability issues
- [Number] test writing limit violations
- [Number] critical issues
- [Number] minor issues
- [Number] over-engineering concerns

See .bot/specs/[this-spec]/verification/spec-verification.md for full details.
```

## Important Constraints

- Compare user's raw answers against requirements.md exactly
- Verify test writing limits strictly: 2-8 tests per implementation task group, max 10 additional tests for testing task group
- Expected total tests: approximately 16-34 tests per feature
- Flag any tasks that call for comprehensive testing, exhaustive coverage, or running full test suites
- Don't add new requirements or specifications
- Focus on alignment and accuracy
- Document everything for transparency
