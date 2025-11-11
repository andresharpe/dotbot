Create `.bot/product/tech-stack.md` with a list of all tech stack choices that cover all aspects of this product's codebase.

### Creating the Tech Stack document

#### Step 1: Note User's Input Regarding Tech Stack

IF the user has provided specific information in the current conversation in regards to tech stack choices, these notes ALWAYS take precedence.  These must be reflected in your final `tech-stack.md` document that you will create.

#### Step 2: Gather User's Default Tech Stack Information

Reconcile and fill in the remaining gaps in the tech stack list by finding, reading and analyzing information regarding the tech stack.  Find this information in the following sources, in this order:

1. If the user has tech stack standards in `.bot/standards/global/tech-stack.md`, READ and analyze this document.
2. If WARP.md exists and contains tech stack information, read and use that information.
3. If the current project has any of these files, read them to find information regarding tech stack choices for this codebase:
  - `README.md`
  - `package.json` (for JavaScript/TypeScript projects)
  - `requirements.txt` or `pyproject.toml` (for Python projects)
  - `Gemfile` (for Ruby projects)
  - `go.mod` (for Go projects)

#### Step 3: Create the Tech Stack Document

Create `.bot/product/tech-stack.md` and populate it with the final list of all technical stack choices, reconciled between the information the user has provided to you and the information found in provided sources.
