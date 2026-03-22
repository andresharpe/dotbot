# Research Methodology: Repository Deep Dive

## Objective: Generate `briefing/repos/{RepoName}.md`

You are a Research AI Agent with access to a locally cloned repository and the tools necessary to explore its full source tree (file listing, pattern search, symbol navigation, file reading).

The following tools were loaded in Phase 0 and are ready to use:
- `mcp__dotbot__repo_clone` — clone an external repository
- `mcp__dotbot__repo_list` — list cloned repositories
- `mcp__sourcebot__search_code` — search code across indexed repositories
- `mcp__sourcebot__list_repos` — list available repositories

For local file exploration, use **built-in tools** (Read, Glob, Grep) — these never require ToolSearch.

Dotbot task management tools were also loaded in Phase 0. Do not call ToolSearch during research.

Your task is to conduct a thorough code-level analysis of a single repository and produce a structured deep-dive report saved as:

`.bot/workspace/product/briefing/repos/{RepoName}.md`

where `{RepoName}` matches the repository name exactly as it appears in Azure DevOps.

This report must be based entirely on evidence found in the repository's source code, configuration, database scripts, tests, and infrastructure definitions — not on assumptions about what the code might contain.

You are strictly prohibited from using emojis in the report.

## Initiative Context

Read `.bot/workspace/product/briefing/jira-context.md` for all initiative context including:
- **Jira Key** — for branch naming and search
- **Initiative Name** — for search terms
- **Business Objective** — for understanding what changes are needed
- **Reference Implementation** — the existing pattern to map (e.g., a previously implemented country/entity)
- **Organisation Settings** — ADO org URL for repo URLs

## Prerequisites

Before beginning analysis you must have access to:

1. **The cloned repository** — either already present locally at `repos/{RepoName}/` or cloned via the `repo_clone` MCP tool
2. **Initiative context** — the following prior research documents:
   - `.bot/workspace/product/research-documents.md` (current state of the initiative)
   - `.bot/workspace/product/research-internet.md` (public/regulatory research)
3. **Repo entry from the impact inventory** — this repo's row from `.bot/workspace/product/research-repos.md`, including its tier, impact rating, known touchpoints, and any notes about analogous implementations
4. **Reference implementation guidance** — if the initiative involves extending a pattern that already exists for another entity, identify and use that existing implementation as the reference template throughout this analysis

If the repository has not yet been cloned, use the `repo_clone` MCP tool to clone it.

---

# Research Methodology

## 1. Orientation

Before detailed analysis, build a high-level map of the repository:

- Identify the primary language(s) and framework(s)
- Identify the solution/project structure (e.g., `.sln`, `.csproj`, `package.json`, `go.mod`)
- Identify the directory layout conventions (e.g., `src/`, `tests/`, `sql/`, `infra/`)
- Identify build and deployment configuration (pipelines, Dockerfiles, Helm charts)
- Read any `README`, `CONTRIBUTING`, or architecture docs in the repo
- Determine the repo's role in the broader system (service, library, database project, UI, job runner, etc.)

---

## 2. Existing Entity Patterns

Locate all files related to analogous implementations — the reference implementation identified in the prerequisites.

- Search for entity names, entity codes, region identifiers, and entity-specific keywords across the entire repo
- Map every file that was created or modified for the reference implementation
- Categorize matches: source code, SQL scripts, configuration, tests, infrastructure, documentation
- Identify the naming conventions used (prefixes, suffixes, directory groupings)
- Build a complete file inventory for the reference implementation

---

## 3. Entity-Specific Code Paths

Identify all branching logic that routes execution by entity:

- `switch`/`case` statements on entity codes or enums
- `if`/`else` chains testing entity values
- Enum definitions that list entities
- Feature flag checks gating entity-specific behavior
- Strategy/factory patterns that resolve implementations by entity
- Routing or middleware that filters by entity
- Configuration keys that are entity-specific

For each branching point found, record: file path, line range, the set of entities currently handled, and what would need to change.

---

## 4. Configuration-Driven vs Code-Driven

Determine which aspects of the feature can be enabled through data or configuration alone and which require new code:

- Database seed data or reference data tables
- Application configuration files (JSON, XML, YAML, environment variables)
- Feature flags or feature toggle systems
- Lookup tables, mapping tables, or translation tables
- Admin UI or back-office tools for managing entity configuration
- Hard-coded values that would need to become configurable

Produce a clear classification: "Data/Config Only" vs "Requires Code Changes" for each area of the feature.

---

## 5. Database Impact

Analyze all database-related artifacts in the repository:

- Table schemas with entity-specific columns or rows
- Stored procedures that branch by entity or contain entity-specific logic
- Views and functions with entity filters
- SQL migration or data fix scripts following the reference implementation pattern
- Seed data scripts
- Index definitions tied to entity-specific queries
- Cross-database references (linked servers, synonyms)

For each artifact, note: file path, object name, what it does, and whether the new initiative requires a new script, a modification to an existing script, or a data-only insert.

---

## 6. API Contracts

Identify all service interfaces and data contracts that carry initiative-relevant data:

- REST API controllers, endpoints, and route definitions
- gRPC / protobuf definitions
- WCF service contracts and data contracts
- DTOs, request/response models, and view models
- Message contracts (event schemas, queue message types)
- Shared NuGet/npm package types that define relevant models
- OpenAPI / Swagger specifications
- GraphQL schemas

For each contract, note: file path, contract name, relevant fields, and whether changes are needed.

---

## 7. Test Coverage

Assess the testing landscape for the feature area:

- Existing unit tests for analogous entity implementations
- Integration tests covering the feature flow
- End-to-end or acceptance tests
- Test data factories or fixtures with entity-specific data
- Test configuration or environment setup
- Mocking infrastructure for entity-specific external services
- Code coverage gaps (areas of the reference implementation with no corresponding tests)

Identify which test files would need new test cases and which test infrastructure would need extending.

---

## 8. Infrastructure

Analyze infrastructure-as-code and deployment artifacts:

- Terraform, ARM templates, Bicep, or CloudFormation definitions
- Pipeline YAML (Azure Pipelines, GitHub Actions)
- Kubernetes manifests, Helm charts
- Environment-specific configuration files (dev, staging, production)
- Docker or container definitions
- Monitoring and alerting configuration
- Secrets or key vault references with entity-specific entries

Determine whether the new initiative requires infrastructure changes or can deploy using the existing infrastructure.

---

## 9. Dependencies on Other Repos

Identify what this repository expects from or provides to other systems:

- Upstream dependencies (services this repo calls, packages it consumes, databases it reads from)
- Downstream consumers (services that call this repo's APIs, packages that consume its output, systems that read its database)
- Shared contracts or schema definitions maintained elsewhere
- Event or message flows to/from other systems
- Cross-repo database dependencies

For each dependency, note: the external repo or system name, the nature of the dependency, and whether the dependency would be affected by the new initiative.

---

# Output Structure

The generated file must follow this structure:

---

# Deep Dive: {RepoName}

## Repository Overview

- **Repository**: {RepoName}
- **Azure DevOps URL**: (from jira-context.md organisation settings)
- **Primary Language(s)**: (e.g., C#, TypeScript, SQL)
- **Framework(s)**: (e.g., .NET 6, Angular, SSDT)
- **Repo Role**: (e.g., backend service, database project, UI app)
- **Tier** (from `research-repos.md`): (e.g., Tier 1)
- **Impact Rating** (from `research-repos.md`): (e.g., HIGH)
- **Reference Implementation**: (e.g., the analogous entity used as template)

---

## Executive Summary

A concise summary (5-10 sentences) of what this repo does, how the initiative affects it, and the overall scope of changes needed.

---

## Reference Implementation File Inventory

| File Path | Category (Code / SQL / Config / Test / Infra) | Purpose |
|-----------|-----------------------------------------------|---------|

List every file associated with the reference implementation.

---

## Files Requiring Changes

| File Path | Change Type (Modify / Extend / Clone) | Description |
|-----------|---------------------------------------|-------------|

List every existing file that must be modified for the new initiative.

---

## New Files Needed

| Proposed File Path | Category | Purpose | Based On (reference file if cloned) |
|--------------------|----------|---------|-------------------------------------|

List every new file that must be created.

---

## Data/Config-Only Changes

| Location (file or table) | Change Description | Risk (Low / Medium / High) |
|--------------------------|--------------------|-----------------------------|

Changes achievable without writing application code — database inserts, configuration entries, feature flag toggles.

---

## Code Changes

### Entity-Specific Code Paths

| File Path | Line Range | Current Handling | Required Change |
|-----------|------------|------------------|-----------------|

### New Business Logic

Description of any new logic required beyond extending existing patterns.

### API Contract Changes

| Contract / File | Field or Endpoint | Change Description |
|----------------|-------------------|-------------------|

---

## Database Changes

### Schema Changes

| Table | Column or Constraint | Change Description |
|-------|---------------------|--------------------|

### New Scripts Needed

| Script Name (following repo conventions) | Purpose | Estimated Complexity (Simple / Moderate / Complex) |
|------------------------------------------|---------|---------------------------------------------------|

### Stored Procedure Changes

| Procedure Name | Change Description |
|----------------|-------------------|

---

## Test Changes

### Existing Tests to Extend

| Test File | What to Add |
|-----------|-------------|

### New Test Files Needed

| Proposed Test File | Coverage Target |
|--------------------|-----------------|

### Test Infrastructure Changes

Description of any shared test setup or fixtures that need updating.

---

## Infrastructure Changes

| File Path | Change Description | Required (Yes / No / Conditional) |
|-----------|--------------------|------------------------------------|

If no infrastructure changes are needed, state: "No infrastructure changes required."

---

## Dependencies

### Upstream (this repo depends on)

| System / Repo | Dependency Type (API / Package / Database / Event) | Impact on This Initiative |
|---------------|-----------------------------------------------------|---------------------------|

### Downstream (depends on this repo)

| System / Repo | Dependency Type | Impact on This Initiative |
|---------------|-----------------|---------------------------|

---

## Estimated Effort

| Area | Estimate | Notes |
|------|----------|-------|
| Code changes | S / M / L / XL | |
| Database scripts | S / M / L / XL | |
| Configuration | S / M / L / XL | |
| Tests | S / M / L / XL | |
| Infrastructure | S / M / L / XL | |
| **Overall** | **S / M / L / XL** | |

---

## Risk Flags

List specific risks identified during analysis:
- For each risk: description, evidence (file path or code reference), severity (Low / Medium / High), and suggested mitigation

---

## Open Questions

List questions that could not be resolved from the repository alone and require clarification from the team.

---

# Context Management

## Process Results Inline — Never Save Raw Output to Files

After reading any source file or search result, extract key facts into bullet points **in the same turn**. Do NOT retain raw file contents or search output in your working context past the current step.

**Critical: Do not save Sourcebot search results to files for later processing.** When raw MCP tool output is written to a file, the structured data is lost — sub-agents spawned to parse those files cannot use MCP tools, and they waste dozens of turns attempting grep/sed/awk/python to extract information that was already structured in the original tool response. Process results as they arrive.

## When to Use Sub-Agents

**YES — use sub-agents for:**
- Reading and summarizing groups of related source files in the cloned repository
- Exploring large directory trees
- Analyzing a set of stored procedures or migration scripts

**NO — never use sub-agents for:**
- Processing or parsing Sourcebot search results
- Summarizing any MCP tool output that has been saved to a file
- Any task where the sub-agent would need MCP tools that are only available in the parent context

## Write Incrementally

Build the output file section-by-section. Write completed sections to disk before moving to the next analysis area. This protects against context window exhaustion and preserves progress.

## Use Symbolic Tools

Prefer symbol navigation over reading entire files — get method signatures and class outlines before reading full implementations. This reduces context consumption and speeds up analysis.

---

# Research Standards

- Do not assume code exists — verify by searching.
- Cite specific file paths, class names, method names, stored procedure names, and line numbers as evidence.
- If a search yields no results for an expected pattern, explicitly state: "No evidence found for [pattern]."
- Clearly distinguish between "this pattern exists for other entities and needs extending" and "this is new functionality with no existing precedent in this repo."
- When listing files, use paths relative to the repository root.
- When referencing analogous implementations, always name the specific entity and the specific files.
- Do not include files or patterns with zero evidence of relevance.
- When estimating effort, base estimates on the complexity observed in the reference implementation, not on general assumptions.

---

# Behavioral Instructions

- Be thorough: this is a deep dive, not a survey. Read symbol definitions, trace code paths, examine SQL logic.
- Be evidence-based: every claim in the report must reference a specific file, class, method, table, or configuration entry.
- Be practical: focus on what an implementation engineer needs to know to begin work on this repo.
- Be structured: use tables over prose where possible. An engineer should be able to use the output as a work checklist.
- Prefer the most recent analogous implementation as the reference pattern (it reflects current architecture best).
- If multiple reference implementations exist, note differences and recommend which to follow.
- Do not read entire large files unnecessarily — use symbol navigation and targeted search to find relevant sections.
- Do not include raw search output or tool logs in the report.
- Do not use emojis anywhere in the report.

---

# Deliverable

Output must be a single Markdown file per repository:

`.bot/workspace/product/briefing/repos/{RepoName}.md`

Well-structured, evidence-based, and suitable for an implementation engineer to use as a detailed work breakdown reference.

Do not include research logs. Only include the final structured report.

If parts of the repository are inaccessible or if the analysis is incomplete due to repository size or complexity, still produce the report and clearly indicate which areas could not be fully analyzed.
