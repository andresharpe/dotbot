# Implementation Research Template

> **Purpose**: Consolidate platform knowledge and initiative-specific technical/regulatory insights to support efficient delivery.
> **Initiative**: (read from `jira-context.md`)
> **Date**: (current date)
> **Status**: Research — living document

---

## 1. Platform/System Overview

Describe the architecture of the affected platform. Draw from deep dive reports to build a consolidated view.

### 1.1 Core Components

| Component | Role |
|-----------|------|
(list each affected repo/service and its role in the platform)

### 1.2 End-to-End Data Flow

```
(ASCII diagram showing how data flows through all affected services from trigger to completion)
```

### 1.3 Key Events / Message Contracts

| Event | Direction | Purpose |
|-------|-----------|---------|
(list message contracts between services)

---

## 2. How Previous Analogous Implementations Were Done

If a reference implementation exists (e.g., the same feature for a different country/entity/region):

### 2.1 Reference Implementation

- Which entity was used as reference
- When it was implemented
- Key files/patterns created

### 2.2 Common Implementation Pattern

Describe the repeatable pattern: what files are created, what config entries are added, what database scripts are run, what tests are written. This is the "cookie cutter" that the new initiative will follow.

### 2.3 Comparison Table

| Aspect | Reference Implementation | This Initiative | Difference |
|--------|------------------------|-----------------|------------|
(compare key dimensions: regulatory model, data format, authentication, etc.)

---

## 3. Initiative-Specific Requirements

From the public/regulatory research and Atlassian context:

### 3.1 Regulatory Requirements

- Mandatory compliance elements
- Deadlines and enforcement dates
- Certification or approval processes

### 3.2 Technical Requirements

- Data format requirements (XML, JSON, specific schemas)
- Authentication/authorization model
- API specifications
- Required fields and validations

### 3.3 Business Requirements

- Business rules specific to this initiative
- Stakeholder expectations
- Integration requirements with external systems

---

## 4. What Differs from Existing Implementations

Unique aspects of this initiative that don't follow the reference pattern:

- New data fields or formats
- Different regulatory model (e.g., clearance vs post-audit)
- New external service integrations
- Different business rules
- Items where the existing platform needs extension (not just configuration)

---

## 5. Extension Points

### 5.1 Configuration-Driven (no code needed)

| Area | Mechanism | What to Configure |
|------|-----------|-------------------|
(feature flags, enum values, config entries that enable the new entity)

### 5.2 Code-Driven (new code needed)

| Area | Reason | Complexity |
|------|--------|------------|
(where the platform doesn't have a plug-in point — new code required)

---

## 6. Technical Implementation Approach per Service

For each affected repo:

### {RepoName}

- **Changes needed**: (summary)
- **Files to modify**: (list with change description)
- **New files to create**: (list with purpose)
- **Config entries**: (list)
- **What's blocked**: (external dependencies)

---

## 7. Dependencies and Blockers

### 7.1 Actionable Now

| Repo | Work | Notes |
|------|------|-------|
(what can proceed immediately)

### 7.2 Blocked

| Repo | Blocker | Expected Resolution | Workaround |
|------|---------|---------------------|------------|
(what's waiting on external dependencies)

---

## 8. Open Questions Requiring Stakeholder Input

| # | Question | Category | Impact If Unresolved |
|---|----------|----------|----------------------|

---

## 9. Risks with Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|

---

## 10. Delivery Estimate

| Phase | Effort | Notes |
|-------|--------|-------|
| Scaffolding (unblocked work) | | |
| Core implementation (after blockers resolved) | | |
| Testing and verification | | |
| Remediation buffer | | |
| **Total** | **X-Y weeks** | |

### Critical Path

(list the sequential chain of dependencies that determines minimum delivery time)

### Parallel Work Lanes

(which repos/phases can proceed concurrently)

---

## 11. Key References

| Type | Reference | Link/Path |
|------|-----------|-----------|
| Jira | Initiative ticket | (from jira-context.md) |
| Confluence | Key documentation | (from jira-context.md) |
| Research | Current status | `research-documents.md` |
| Research | Public/regulatory | `research-internet.md` |
| Research | Repo inventory | `research-repos.md` |
| Deep Dives | Per-repo analysis | `repos/*.md` |
