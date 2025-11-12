# Spec Research

**Agent:** @.bot/agents/spec-shaper.md

## Core Responsibilities

1. **Read Initial Idea**: Understand what the user wants to build
2. **Analyze Product Context**: Understand product mission, roadmap, and how this feature fits
3. **Ask Clarifying Questions**: Generate targeted questions WITH visual asset request AND reusability check
4. **Process Answers**: Analyze responses and any provided visuals
5. **Ask Follow-ups**: Based on answers and visual analysis if needed
6. **Save Requirements**: Document the requirements in `.bot/specs/[spec-name]/planning/requirements.md`

## Workflow

### Step 1: Understand Product Context

Read these files if they exist to understand the broader product context:
- `.bot/product/mission.md` - Product's overall mission and purpose
- `.bot/product/roadmap.md` - Features completed and where this fits
- `.bot/product/tech-stack.md` or `.bot/standards/global/tech-stack.md` - Technologies in use

### Step 2: Generate First Round of Questions

Based on the initial idea, generate 4-8 targeted, NUMBERED questions that explore requirements while suggesting reasonable defaults.

**CRITICAL: Always include the visual asset request AND reusability question at the END of your questions.**

**Question generation guidelines:**
- Start each question with a number
- Propose sensible assumptions based on best practices
- Frame questions as "I'm assuming X, is that correct?"
- Make it easy for users to confirm or provide alternatives

**Required output format:**
```
Based on your idea for [spec name], I have some clarifying questions:

1. I assume [specific assumption]. Is that correct, or [alternative]?
2. I'm thinking [specific approach]. Should we [alternative]?
3. [Continue with numbered questions...]
[Last numbered question about exclusions]

**Existing Code Reuse:**
Are there existing features in your codebase with similar patterns we should reference? For example:
- Similar UI components or page layouts
- Related backend logic or service objects
- Existing models or controllers with similar functionality

Please provide file/folder paths or names of these features if they exist.

**Visual Assets Request:**
Do you have any design mockups, wireframes, or screenshots that could help guide the development?

If yes, please place them in: `.bot/specs/[spec-name]/planning/visuals/`

Use descriptive file names like:
- homepage-mockup.png
- dashboard-wireframe.jpg
- lofi-form-layout.png

Please answer the questions above and let me know if you've added any visual files or can point to similar existing features.
```

**STOP and wait for user response.**

### Step 3: Process Answers and Check for Visuals

After receiving user's answers:

1. Store the user's answers for later documentation

2. **Check for visual assets** - Look for files in `.bot/specs/[spec-name]/planning/visuals/`

3. IF visual files are found:
   - Analyze EACH visual file
   - Note key design elements, patterns, and user flows
   - Check filenames for low-fidelity indicators (lofi, lo-fi, wireframe, sketch, rough, etc.)

4. IF user provided paths or names of similar features:
   - Make note of these paths/names for the spec writer to reference

### Step 4: Generate Follow-up Questions (if needed)

Determine if follow-up questions are needed based on:

**Visual-triggered follow-ups:**
- If visuals were found but user didn't mention them
- If filenames suggest low-fidelity mockups (clarify design intent)
- If visuals show features not discussed in answers

**Reusability follow-ups:**
- If user didn't provide similar features but the spec seems common
- If provided paths seem incomplete

**User's Answers-triggered follow-ups:**
- Vague requirements need clarification
- Missing technical details
- Unclear scope boundaries

**If follow-ups needed, ask them and STOP to wait for responses.**

### Step 5: Save Complete Requirements

After all questions are answered, create `.bot/specs/[spec-name]/planning/requirements.md`:

```markdown
# Spec Requirements: [Spec Name]

## Initial Description
[User's original spec description]

## Requirements Discussion

### First Round Questions

**Q1:** [First question asked]
**Answer:** [User's answer]

**Q2:** [Second question asked]
**Answer:** [User's answer]

[Continue for all questions]

### Existing Code to Reference

**Similar Features Identified:**
- Feature: [Name] - Path: `[path provided by user]`
- Components to potentially reuse: [user's description]
- Backend logic to reference: [user's description]

[Or if none:] No similar existing features identified for reference.

### Follow-up Questions
[If any were asked]

**Follow-up 1:** [Question]
**Answer:** [User's answer]

## Visual Assets

### Files Provided:
- `filename.png`: [Description of what it shows from your analysis]
- `filename2.jpg`: [Key elements observed from your analysis]

### Visual Insights:
- [Design patterns identified]
- [User flow implications]
- [UI components shown]
- [Fidelity level: high-fidelity mockup / low-fidelity wireframe]

[Or if none:] No visual assets provided.

## Requirements Summary

### Functional Requirements
- [Core functionality based on answers]
- [User actions enabled]
- [Data to be managed]

### Reusability Opportunities
- [Components that might exist already based on user's input]
- [Backend patterns to investigate]
- [Similar features to model after]

### Scope Boundaries
**In Scope:**
- [What will be built]

**Out of Scope:**
- [What won't be built]
- [Future enhancements mentioned]

### Technical Considerations
- [Integration points mentioned]
- [Existing system constraints]
- [Technology preferences stated]
- [Similar code patterns to follow]
```

### Step 6: Output Completion

Output to user:

```
Requirements research complete!

✅ Processed [X] clarifying questions
✅ Visual check performed: [Found and analyzed Y files / No files found]
✅ Reusability opportunities: [Identified Z similar features / None identified]
✅ Requirements documented comprehensively

Requirements saved to: `.bot/specs/[spec-name]/planning/requirements.md`

Ready for specification creation.
```

## Important Constraints

- Always check visuals folder after receiving user answers
- Save user's exact answers, not interpretations
- Document all visual findings including fidelity level
- Document paths to similar features for spec-writer to reference
- Keep follow-ups minimal (1-3 questions max)
