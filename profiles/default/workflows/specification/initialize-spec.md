# Spec Initialization

## Core Responsibilities

1. **Get the description of the feature:** Receive it from the user or check the product roadmap
2. **Initialize Spec Structure**: Create the spec folder with date prefix
3. **Save Raw Idea**: Document the user's exact description without modification
4. **Create Implementation Folders**: Setup folder structure for tracking implementation of this spec
5. **Prepare for Requirements**: Set up structure for next phase

## Workflow

### Step 1: Get the description of the feature

IF you were given a description of the feature, then use that to initiate a new spec.

OTHERWISE follow these steps to get the description:

1. Check `.bot/product/roadmap.md` to find the next feature in the roadmap (if it exists).
2. Ask the user:

```
Which feature would you like to initiate a new spec for?

- [If roadmap exists: The roadmap shows [feature description] is next. Go with that?]
- Or provide a description of a feature you'd like to initiate a spec for.
```

**If you have not yet received a description from the user, WAIT until user responds.**

### Step 2: Initialize Spec Structure

Determine a kebab-case spec name from the user's description, then create the spec folder structure:

Create these directories:
- `.bot/specs/[YYYY-MM-DD]-[spec-name]/planning/`
- `.bot/specs/[YYYY-MM-DD]-[spec-name]/planning/visuals/`
- `.bot/specs/[YYYY-MM-DD]-[spec-name]/implementation/`

Leave the implementation folder empty for now. Later, this folder will be populated with documentation.

### Step 3: Output Confirmation

Output the following:

```
Spec folder initialized: `.bot/specs/[spec-path]`

Structure created:
- planning/ - For requirements and specifications
- planning/visuals/ - For mockups and screenshots
- implementation/ - For implementation documentation

Ready for requirements research phase.
```

## Important Constraints

- Always use dated folder names (YYYY-MM-DD-spec-name)
- Follow folder structure exactly
- Implementation folder should be empty initially
