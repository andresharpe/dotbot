# Research Methodology: Deep Sourcebot Research

## Objective: Generate `research-repos.md`

You are a Research AI Agent with access to Sourcebot MCP tools for searching code across the organisation's repository estate.

The following tools were loaded in Phase 0 and are ready to use:
- `mcp__sourcebot__ask_codebase` — ask natural-language questions; returns synthesized answers, not raw code results (~500-2000 tokens vs ~10,000 for search_code)
- `mcp__sourcebot__search_code` — search code across all indexed repositories (use with `includeCodeSnippets: false` for compact results)
- `mcp__sourcebot__list_repos` — list available repositories
- `mcp__sourcebot__read_file` — read specific files from repositories
- `mcp__sourcebot__list_tree` — browse repository directory trees

Dotbot task management tools were also loaded in Phase 0. Do not call ToolSearch during research.

Your task is to discover all repositories relevant to the initiative using Sourcebot code search, classify them by relevance and impact, and produce a structured assessment saved as:

`.bot/workspace/product/research-repos.md`

**Important — Seed File Merge:** If `research-repos.md` already exists, it is a seed file generated from briefing documents (Phase 01). Seed entries represent repos explicitly named by the user and are authoritative. When writing your results:
- **Preserve all seed entries** — do not remove or downgrade repos that came from the seed
- **Merge Sourcebot findings** — add any additional repos discovered through code search
- **Enrich seed entries** — update Purpose, Impact, or Project fields with evidence from Sourcebot if you found better information, but do not lower impact classifications from the seed
- If a seed entry has `TBD` for the Project field and you discover the correct project via Sourcebot, fill it in

This document must be based on evidence found in actual source code, database scripts, configuration files, and test suites — not assumptions about what might exist.

You are strictly prohibited from using emojis in the report.

## Initiative Context

Read `.bot/workspace/product/briefing/jira-context.md` for all initiative context including:
- **Jira Key** — use for searching code comments, ticket references
- **Initiative Name** — use as search term
- **Business Objective** — understand what functionality to search for
- **Components & Labels** — identify affected system areas
- **Reference Implementation** — find the existing pattern to map
- **Organisation Settings** — ADO org URL and default projects for scoping searches

Also read prior research if available:
- `.bot/workspace/product/research-documents.md` — current state context
- `.bot/workspace/product/research-internet.md` — domain context

---

# Research Methodology

## 1. Establish Search Terms

Before scanning repositories, derive search terms from the initiative context and organize them by specificity. **Specific terms first, broad terms last.**

### Priority Hierarchy

**P1 — Exact Identifiers** (search these first, zero ambiguity)
- Jira ticket keys (e.g., `PROJ-1234`)
- Epic or initiative identifiers from the briefing
- Known feature flag names or configuration keys

**P2 — Domain-Specific Names** (high signal, low noise)
- Third-party provider names (e.g., "Edicom", "FBR", "Avalara")
- Domain-specific technical terms (e.g., "PaymentGateway", "RefundPolicy", "SettlementBatch")
- Named system components, service names, or API endpoint paths from the briefing

**P3 — Reference Implementation Patterns** (find where parallel changes are needed)
- File and class name patterns from the analogous implementation (e.g., if the reference is "Spain", search for `Spain`, `ES_`, `SpainProvider`)
- Stored procedure naming patterns (e.g., `usp_*Spain*`)
- Configuration section names from the reference implementation

**P4 — Scoped Entity Identifiers** (use codes, not names)
- Country/region CODES: `PK`, `SA`, `MY` — short, specific, fewer false positives
- Enum values and lookup codes from the domain
- ISO standard codes relevant to the initiative

**P5 — Broad Terms** (use only to fill gaps, expect noise)
- Full country or region names (e.g., "Germany", "Brazil")
- Generic domain words (e.g., "invoice", "tax", "compliance")
- Use these ONLY if P1-P4 searches have not yet surfaced a repository you have reason to believe exists

### When NOT to Search

- **Skip P5 terms entirely** if P1-P4 already found all repositories mentioned in prior research or the initiative briefing
- **Do not search generic infrastructure terms** (e.g., "logging", "authentication") unless the briefing specifically identifies infrastructure changes
- **Do not repeat a search** with a broader term if a narrower term already found the same repository

### Handling Broad Results

If a search term returns excessive matches (100+ results):
1. **Do not save the raw results to a file** — process them in the current turn
2. **Combine the broad term with a narrower qualifier** (e.g., search `Germany AND provider` instead of `Germany`)
3. **Filter by file path or repository** if Sourcebot supports it
4. **Skip the term** if the repositories it matches are already covered by earlier, more specific searches

---

## 2. Repository Discovery

Use `list_repos` to understand the full repository landscape before searching.

### Search Execution Protocol

Discovery uses a two-phase approach to stay within the context window. **Phase A** casts a wide net with compact results; **Phase B** fills gaps with targeted verification.

#### Phase A — Discovery via `ask_codebase` (primary, ~5-8 calls)

Use `mcp__sourcebot__ask_codebase` with natural-language questions to discover repos efficiently. Each call returns ~500-2000 tokens of synthesized results instead of ~10,000 tokens of raw code.

Example questions (adapt to the initiative):
- "Which repositories reference {Jira key} in code comments, configs, or documentation?"
- "Which repositories contain {domain entity} provider logic, database scripts, or configuration?"
- "Which repositories implement {reference implementation pattern} for country-specific features?"
- "Which repositories have SQL stored procedures related to {domain concept}?"
- "Which repositories contain API endpoints or service contracts for {feature area}?"

For each response:
1. **Extract repo names, projects, and relevance notes inline**
2. **Classify each repo** as Direct, Indirect, or Noise (discard Noise immediately)
3. **Record findings** using the per-repository checklist below
4. **Move to the next question** — do not spawn sub-agents to process results

#### Phase B — Verification via `search_code` (targeted, ~8-12 calls)

Use `mcp__sourcebot__search_code` ONLY for:
- Verifying specific P1 identifiers (Jira keys, feature flags) that `ask_codebase` may have missed
- Filling gaps — repos you have reason to believe exist but Phase A did not surface
- Confirming exact file paths or match counts for HIGH-impact repos

**Mandatory parameters for every `search_code` call:**
- **Always** set `includeCodeSnippets: false` — file paths and repo names suffice for the repo-level report
- **Always** set `filterByRepos` when verifying a known repo — don't scan the entire estate
- **Set** `filterByLanguages` when searching SQL or specific code types — reduces irrelevant matches

Skip P5 broad terms entirely if Phase A already found all expected repos.

### Search Parameters Reference

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `includeCodeSnippets` | `false` (always) | Keeps results compact; file paths suffice for repo-level report |
| `filterByRepos` | Set when verifying a specific repo | Prevents noise from unrelated repos |
| `filterByLanguages` | Set when searching SQL or specific code | Reduces irrelevant matches |

### What to Record Per Repository

For each repository that appears in search results with relevant (non-noise) matches:

- Repository name and ADO project
- Which search terms matched and approximate count of relevant matches
- Match categories: code, configuration, SQL, test, documentation, infrastructure
- Whether matches are in active code or archived/deprecated paths
- Whether the repository contains direct feature logic or only indirect references
- Brief note on what the repository appears to own (one sentence)

### Volume Thresholds

| Result Count | Interpretation | Action |
|-------------|----------------|--------|
| 0 matches | Term may be misspelled or feature is genuinely absent | Check spelling; try alternate forms; move on |
| 1-30 matches | Good specificity | Process all matches, classify each |
| 30-100 matches | Moderate noise likely | Scan for repository-level patterns; focus on direct matches |
| 100+ matches | Term is too broad | Refine: combine with qualifier, filter by path, or skip if repos already covered |

---

## 3. Pattern Analysis

For initiatives where similar implementations already exist for other countries/regions/entities:

- Identify the "reference implementation" (the most recent or best-documented existing implementation)
- Map every file, class, stored procedure, config entry, and test that was touched for the reference implementation
- Assess which of those same locations would need changes for the new initiative
- Identify country/region-specific vs. generic/shared components

---

## 4. Deep Dive Analysis

For repositories classified as HIGH impact, conduct a detailed analysis:

- Identify specific database tables, stored procedures, and views involved
- Identify specific classes and methods
- Identify data fix script patterns (SQL migration scripts)
- Identify feature flag / feature switch mechanisms
- Identify configuration-driven vs. code-driven components
- Determine whether changes are data-only (DB scripts) or require code changes
- Map the end-to-end data flow through the system

---

## 5. Dependency and Integration Mapping

Identify cross-repository dependencies:

- Service references (WCF, REST, gRPC) that carry relevant data fields
- Shared NuGet/npm packages with relevant types or enums
- Event/message contracts (protobuf, event schemas) that include relevant fields
- Database dependencies (cross-database queries, linked servers)
- Infrastructure dependencies (queues, topics, storage accounts)

---

# Impact Classification

Classify each affected repository into one of six tiers:

## Tier 1: Core Feature Repos (Directly Affected)

Repositories that own the primary feature logic and would require new entity-specific code or configuration.

## Tier 2: Business Logic & UI Repos

Repositories containing business rules, service agreements, or user interfaces that surface the feature to end users.

## Tier 3: Integration & API Repos

Repositories that pass feature-related data between systems via APIs, service references, or message contracts.

## Tier 4: Financial & ERP Repos

Repositories handling financial processing, ERP integration, or reporting that consumes feature output.

## Tier 5: Test Automation Repos

Repositories containing automated tests (UI, API, integration, E2E) for the feature.

## Tier 6: Supporting / Peripheral Repos

Repositories with minor or indirect references — monitoring tools, documentation bots, service catalogs, knowledge bases.

Within each tier, assign an impact level:

- **HIGH** — New code, configuration, or scripts definitely needed
- **MEDIUM** — Changes likely needed but scope uncertain
- **LOW** — Changes possible but may not be required
- **LOW-MEDIUM** — Between low and medium; depends on implementation decisions

---

# Output Structure

The generated file must follow this structure:

---

# Repos Potentially Affected

## Context

- Brief description of the initiative
- Current state of the entity in the system
- Reference to existing analogous implementations
- Link to prior research documents if available

---

## Tier 1: Core Feature Repos (Directly Affected)

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|

---

## Tier 2: Business Logic & UI Repos

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|

---

## Tier 3: Integration & API Repos

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|

---

## Tier 4: Financial & ERP Repos

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|

---

## Tier 5: Test Automation Repos

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|

---

## Tier 6: Supporting / Peripheral Repos

| Repo | Project | Purpose | Impact |
|------|---------|---------|--------|

---

## Summary: Key Repos by Priority

### Must-change (repos where changes are definitely required)

Numbered list with repo name and one-line description of what changes.

### Likely-change (repos where changes are probable)

Numbered list continuing from above.

### Possibly-change (repos where changes depend on implementation decisions)

Brief list or summary.

---

## Deep Dive: [Primary Repo Name]

For each HIGH-impact repo that warrants detailed analysis, include a deep dive section covering:

### Database Tables Involved

| Table | Role |
|-------|------|

### Key Stored Procedures

| Stored Procedure | What It Does |
|------------------|--------------|

### Business Logic (Code)

| File / Class | Role |
|-------------|------|

### Data Fix Script Pattern

Based on the reference implementation, describe the scripts that would be needed:
- Script purpose
- Suggested naming convention
- Step-by-step contents

### What Would Change

- Definite code changes
- Definite data/config changes
- Possible code changes (conditional on implementation decisions)

---

## End-to-End Data Flow

ASCII or text-based diagram showing how data flows through the affected systems from initiation to completion.

---

# Context Management

## Token Budget

Context exhaustion is the primary failure mode for Sourcebot research tasks. Stay within these limits:

- **Maximum 20 Sourcebot tool calls total** (`ask_codebase` + `search_code` combined)
- **Prefer `ask_codebase` for discovery** — compact synthesized answers (~500-2000 tokens each)
- **Use `search_code` sparingly for verification only**, always with `includeCodeSnippets: false`
- **If approaching 15 tool calls**, stop broadening and proceed to classification
- **A partial-but-delivered report is better than a context-exhausted session that produces nothing**

## Process Results Inline — Never Save Raw Output to Files

After each Sourcebot search or file read, extract key facts into bullet points **in the same turn**. Do NOT retain raw search output in your working context past the current step.

**Critical: Do not save Sourcebot search results to files for later processing.** This is the single most common failure mode in research tasks. When raw MCP tool output is written to a file, the structured data is lost — sub-agents spawned to parse those files cannot use MCP tools, and they waste dozens of turns attempting grep/sed/awk/python to extract information that was already structured in the original tool response. Process results as they arrive.

## When to Use Sub-Agents

**YES — use sub-agents for:**
- Reading specific source files in a cloned repository (Read, Glob, Grep)
- Exploring directory trees of cloned repositories
- Summarizing a group of related source files that are already on disk

**NO — never use sub-agents for tasks requiring MCP tools:**
- Calling Sourcebot tools (`search_code`, `ask_codebase`, `list_repos`) — sub-agents cannot access MCP tools
- Processing Sourcebot output saved to a file — the structured data is lost in serialization
- Any task where the sub-agent would need MCP tools that are only available in the parent context

## Write Incrementally

Build the output file section-by-section. Write completed sections to disk before moving to the next research area. This protects against context window exhaustion and preserves progress.

## Working Notes Pattern

Maintain a compact per-repository tracking format in your working context:

```
REPO: {name} | PROJECT: {project} | TERMS: P1-key, P2-provider | MATCHES: 12 code, 3 sql | TYPE: direct | NOTES: owns provider logic
```

This is for your own tracking only — do not include working notes in the final report.

---

# Research Standards

- Do not assume code exists — verify by searching.
- Cite specific file paths, class names, method names, or stored procedure names as evidence.
- If a repository appears in search results but the matches are irrelevant, exclude it.
- Clearly distinguish between "this repo has the feature implemented for other entities" (pattern exists, needs extension) and "this repo references feature data but owns no feature logic" (may need no changes).
- If you cannot access a repository, explicitly state: "Repository not accessible for analysis."
- Do not include repositories with zero evidence of relevance.
- When identifying stored procedures or code, include enough context to understand what they do without reading the full source.

---

# Behavioral Instructions

- Be systematic: scan broadly first, then drill into high-impact repos.
- Be evidence-based: every repo in the report must have concrete search evidence justifying its inclusion.
- Be practical: focus on what an implementation team needs to know, not academic completeness.
- Be concise: tables over prose where possible.
- Prefer the most recent analogous implementation as the reference pattern (it reflects current architecture best).
- When multiple repos serve similar functions (e.g., v2 and v3 of an API), note which is actively used.
- Do not use emojis anywhere in the report.

---

# Deliverable

Output must be a single Markdown file:

`.bot/workspace/product/research-repos.md`

Well-structured, evidence-based, and suitable for engineering leads and delivery managers to use for sprint planning and sizing.

Do not include raw search logs. Only include the final structured report.

If access to some repositories is restricted, still produce the report and clearly indicate which repos could not be analyzed.
