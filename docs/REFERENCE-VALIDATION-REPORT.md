# dotbot Reference Validation Report

**Generated:** 2025-11-12  
**Purpose:** Ensure all agents, commands, standards, and workflows are properly documented and cross-referenced

---

## Executive Summary

✅ **Overall Status:** Most references are properly structured  
⚠️ **Issues Found:** 7 areas needing attention  
📝 **Recommendations:** 5 enhancement opportunities

---

## 1. Inventory Summary

### Agents (8 files)
1. `implementation-verifier.md` - End-to-end implementation verifier
2. `implementer.md` - Software implementation specialist
3. `product-planner.md` - Product documentation and roadmap creator
4. `spec-initializer.md` - Spec folder structure initialization
5. `spec-shaper.md` - Requirements research specialist
6. `spec-verifier.md` - Specification verification
7. `spec-writer.md` - Technical specification writer
8. `tasks-list-creator.md` - Tasks list planning and creation

### Commands (7 files)
1. `create-tasks.md` - Break specs into implementable tasks
2. `implement-tasks.md` - Execute tasks with verification steps
3. `improve-rules.md` - Optimize WARP.md project rules
4. `orchestrate-tasks.md` - Coordinate implementation across task groups
5. `plan-product.md` - Create product mission, roadmap, and tech stack
6. `shape-spec.md` - Interactively explore and scope features
7. `write-spec.md` - Write detailed technical specifications

### Standards (15 files)

**Global (6 files):**
- `coding-style.md`
- `commenting.md`
- `conventions.md`
- `error-handling.md`
- `tech-stack.md`
- `validation.md`

**Backend (4 files):**
- `api.md`
- `migrations.md`
- `models.md`
- `queries.md`

**Frontend (4 files):**
- `accessibility.md`
- `components.md`
- `css.md`
- `responsive.md`

**Testing (1 file):**
- `test-writing.md`

### Workflows (15 files)

**Planning (4 files):**
- `gather-product-info.md`
- `create-product-mission.md`
- `create-product-roadmap.md`
- `create-product-tech-stack.md`

**Specification (4 files):**
- `initialize-spec.md`
- `research-spec.md`
- `verify-spec.md`
- `write-spec.md`

**Implementation (3 files):**
- `create-tasks-list.md`
- `implement-tasks.md`
- `verify-implementation.md`

**Implementation Verification (4 files):**
- `verify-tasks.md`
- `update-roadmap.md`
- `run-all-tests.md`
- `create-verification-report.md`

---

## 2. README.md Accuracy Check

### ✅ Correct Counts
- **Agents:** README claims 8, actual: 8 ✓
- **Commands:** README claims 7, actual: 7 ✓
- **Standards:** README claims 15, actual: 15 ✓
- **Workflows:** README claims 15, actual: 15 ✓

### ✅ Naming Accuracy
All agents, commands, standards, and workflows listed in README match actual files.

### ⚠️ Minor Inconsistency
README line 141 mentions "Commands (7 total)" but the Warp slash command section (lines 50-59) lists 6 commands:
- dotbot-1-gather-product-info
- dotbot-2-research-spec
- dotbot-3-write-spec
- dotbot-4-create-tasks-list
- dotbot-5-implement-tasks
- dotbot-6-verify-implementation

**Missing from Warp commands section:**
- `orchestrate-tasks` command
- `improve-rules` command

**Recommendation:** Add these to the Quick Start workflow section or note they are optional/advanced.

---

## 3. Command → Workflow References

### ✅ Proper References Found

| Command | References Workflow | Status |
|---------|-------------------|--------|
| `plan-product.md` | `.bot/workflows/planning/` | ✓ Generic reference |
| `shape-spec.md` | `.bot/workflows/specification/write-spec.md` | ✓ Specific |
| `write-spec.md` | `.bot/workflows/specification/write-spec.md` | ✓ Specific |
| `create-tasks.md` | `.bot/workflows/implementation/implement-tasks.md` | ⚠️ Wrong workflow |
| `implement-tasks.md` | `.bot/workflows/implementation/implement-tasks.md` | ✓ Specific |
| `orchestrate-tasks.md` | `.bot/workflows/implementation/implement-tasks.md` | ✓ Partial |

### ⚠️ Issues Found

**Issue 1: `create-tasks.md` references wrong workflow**
- **Current:** References `.bot/workflows/implementation/implement-tasks.md` (line 110)
- **Should be:** `.bot/workflows/implementation/create-tasks-list.md`
- **Impact:** Users following the command will get the wrong workflow instructions

**Issue 2: `plan-product.md` has generic reference**
- **Current:** References `.bot/workflows/planning/` (line 139)
- **Improvement:** Should list specific workflows:
  - `.bot/workflows/planning/gather-product-info.md`
  - `.bot/workflows/planning/create-product-mission.md`
  - `.bot/workflows/planning/create-product-roadmap.md`
  - `.bot/workflows/planning/create-product-tech-stack.md`

**Issue 3: `improve-rules.md` has no workflow reference**
- This command doesn't reference any workflow file
- Consider if this is intentional or if a workflow should be created

---

## 4. Command → Standards References

### ✅ Most Commands Reference Standards

All commands (except `improve-rules.md`) reference standards appropriately:

**Standard pattern used:**
```markdown
## Standards

This command follows:
- `.bot/standards/global/coding-style.md`
- `.bot/standards/global/error-handling.md`
```

### ⚠️ Limited Standards Scope

Most commands only reference 2 global standards. Consider:
- Should `implement-tasks.md` reference more standards (validation, commenting, conventions)?
- Should specialized commands reference specialized standards (backend/frontend)?

**Current `implement-tasks.md` references (lines 135-140):**
- ✓ coding-style.md
- ✓ error-handling.md
- ✓ validation.md
- ✓ commenting.md
- ✓ conventions.md
- ✓ "Any project-specific standards"

This is actually comprehensive! ✓

---

## 5. Workflow → Agent References

### ❗ Critical Finding: Workflows Don't Directly Invoke Agents

**Discovery:** Agent files exist but are **not directly referenced** by workflows or commands.

**Current Architecture:**
- Agent files define personas/roles (e.g., "You are a spec writer...")
- Workflows contain instructions for AI agents to follow
- Commands reference workflows and standards
- **No explicit agent loading mechanism found**

**Hypothesis:**
The agents are intended as **optional persona files** that:
1. Users can manually load into their AI chat context
2. Provide role-specific guidance for specialized tasks
3. Are not programmatically invoked by the system

### ⚠️ Agent File References

Only 1 workflow mentions an agent:
- `research-spec.md` line 201: "for spec-writer to reference"

**Issue:** If agents are meant to be invoked, there's no mechanism. If they're optional, this should be documented.

---

## 6. Workflow → Standards References

### ✅ Key Workflows Reference Standards

**Examples found:**
- `research-spec.md` line 19: References tech-stack.md
- `create-product-tech-stack.md` line 13: References tech-stack.md
- Multiple agent files reference standards properly

### ✅ Agent Files Show Proper Pattern

All agent files that reference standards use the correct format:
```markdown
## User Standards & Preferences Compliance

IMPORTANT: Ensure that [work] IS ALIGNED and DOES NOT CONFLICT with:
- `.bot/standards/*` (if applicable)
- WARP.md (if it exists)
- Any project-specific standards provided
```

---

## 7. Cross-Reference Matrix

### Commands ↔ Workflows

| Command | Expected Workflow | Actual Reference | Status |
|---------|------------------|------------------|--------|
| plan-product | planning/gather-product-info | planning/ (generic) | ⚠️ Incomplete |
| shape-spec | specification/research-spec | specification/write-spec | ⚠️ Mismatched |
| write-spec | specification/write-spec | specification/write-spec | ✓ |
| create-tasks | implementation/create-tasks-list | implementation/implement-tasks | ❌ Wrong |
| implement-tasks | implementation/implement-tasks | implementation/implement-tasks | ✓ |
| orchestrate-tasks | N/A (orchestration) | implementation/implement-tasks | ✓ Partial |
| improve-rules | N/A | None | ⚠️ No workflow |

### Workflows ↔ Agents (Expected vs. Actual)

| Workflow | Expected Agent | Actual Reference | Status |
|----------|---------------|------------------|--------|
| gather-product-info | product-planner | None | ⚠️ |
| research-spec | spec-shaper | None (mentions spec-writer once) | ⚠️ |
| write-spec | spec-writer | None | ⚠️ |
| create-tasks-list | tasks-list-creator | None | ⚠️ |
| implement-tasks | implementer | None | ⚠️ |
| verify-implementation | implementation-verifier | None | ⚠️ |

**Pattern:** Agent files exist but are **never explicitly invoked** by workflows.

---

## 8. Issues Summary

### Critical (Fix Required)

1. **`create-tasks.md` references wrong workflow**
   - Line 110 references `implement-tasks.md` instead of `create-tasks-list.md`
   - **Fix:** Change line 110 to reference correct workflow

### High Priority (Should Fix)

2. **`shape-spec.md` references wrong workflow**
   - Line 111 references `write-spec.md` but should reference `research-spec.md`
   - **Fix:** Update to reference the research workflow

3. **Agent invocation architecture is unclear**
   - Agent files exist but are never explicitly loaded
   - **Fix:** Document in README or CONTRIBUTING how agents should be used

### Medium Priority (Consider Fixing)

4. **`plan-product.md` has generic workflow reference**
   - Could be more specific about which workflows to follow
   - **Fix:** List all 4 planning workflows explicitly

5. **README Quick Start omits 2 commands**
   - `orchestrate-tasks` and `improve-rules` not in workflow list
   - **Fix:** Add or mark as optional/advanced

### Low Priority (Enhancement)

6. **Limited cross-referencing**
   - Workflows don't link back to agents that should use them
   - **Enhancement:** Add "Recommended Agent" section to workflows

7. **No validation tooling**
   - Manual checking required to validate references
   - **Enhancement:** Create validation script

---

## 9. Recommendations

### 1. Fix Critical References

**File: `profiles/default/commands/create-tasks.md`**
```markdown
# Current (line 110):
- `.bot/workflows/implementation/implement-tasks.md`

# Should be:
- `.bot/workflows/implementation/create-tasks-list.md`
```

**File: `profiles/default/commands/shape-spec.md`**
```markdown
# Current (line 111):
- `.bot/workflows/specification/write-spec.md` (adapted for shaping)

# Should be:
- `.bot/workflows/specification/research-spec.md`
```

### 2. Document Agent Architecture

Add to README or CONTRIBUTING:

```markdown
## Using Agent Personas

Agent files in `.bot/agents/` provide role-specific guidance:

**Manual Loading:**
When you need specialized guidance, load the appropriate agent:
- "Load @.bot/agents/spec-writer.md before proceeding"
- "Follow @.bot/agents/implementer.md for this task"

**Automatic Context (Future):**
Agent files may be automatically included in workflow context
based on the command being executed.
```

### 3. Enhance `plan-product.md`

**Current (line 139):**
```markdown
This command follows:
- `.bot/workflows/planning/` (when created)
```

**Improved:**
```markdown
This command follows these workflows in sequence:
- `.bot/workflows/planning/gather-product-info.md`
- `.bot/workflows/planning/create-product-mission.md`
- `.bot/workflows/planning/create-product-roadmap.md`
- `.bot/workflows/planning/create-product-tech-stack.md`
```

### 4. Update README Quick Start

Add optional commands section:

```markdown
### Optional Advanced Workflows

**Orchestration for complex specs:**
```
Ctrl-Shift-R → dotbot-orchestrate-tasks     # Manage multi-group implementation
```

**Optimize your project rules:**
```
Ctrl-Shift-R → dotbot-improve-rules         # Refine WARP.md for better AI guidance
```
```

### 5. Create Validation Script

Create `scripts/validate-references.ps1`:
```powershell
# Validate that all workflow references in commands point to existing files
# Check that agent counts match reality
# Verify standards references are valid
```

---

## 10. Validation Checklist

Use this checklist when adding new components:

### Adding a New Command
- [ ] Command references appropriate workflow(s)
- [ ] Command references relevant standards
- [ ] Command is documented in README
- [ ] Command follows template structure
- [ ] Warp command mapping created (if applicable)

### Adding a New Workflow
- [ ] Workflow is referenced by at least one command
- [ ] Workflow references relevant standards
- [ ] Workflow is listed in README
- [ ] Dependencies are documented

### Adding a New Agent
- [ ] Agent purpose is documented
- [ ] Agent references workflow(s) it should follow
- [ ] Agent references standards it should follow
- [ ] Agent is listed in README
- [ ] Usage instructions provided

### Adding a New Standard
- [ ] Standard is referenced by relevant commands/workflows/agents
- [ ] Standard is listed in README
- [ ] Standard category (global/backend/frontend/testing) is appropriate

---

## Conclusion

The dotbot reference system is **mostly well-structured** with clear separation of concerns:
- ✅ Commands reference workflows and standards appropriately
- ✅ README accurately documents all components
- ✅ File organization is logical and consistent
- ⚠️ Agent invocation architecture needs clarification
- ❌ 2 commands reference wrong workflows (critical fix needed)

**Priority Actions:**
1. Fix `create-tasks.md` workflow reference (5 min)
2. Fix `shape-spec.md` workflow reference (5 min)
3. Document agent usage pattern in README (15 min)
4. Update README Quick Start with optional commands (10 min)

**Total estimated fix time:** ~35 minutes

---

## Appendix: Complete Reference Map

### Command → Workflow Mapping
```
plan-product         → workflows/planning/* (4 files)
shape-spec           → workflows/specification/research-spec.md
write-spec           → workflows/specification/write-spec.md
create-tasks         → workflows/implementation/create-tasks-list.md
implement-tasks      → workflows/implementation/implement-tasks.md
orchestrate-tasks    → workflows/implementation/* (orchestration layer)
improve-rules        → (no workflow - standalone)
```

### Workflow → Agent Mapping (Recommended)
```
gather-product-info         → product-planner
create-product-mission      → product-planner
create-product-roadmap      → product-planner
create-product-tech-stack   → product-planner
initialize-spec             → spec-initializer
research-spec               → spec-shaper
write-spec                  → spec-writer
verify-spec                 → spec-verifier
create-tasks-list           → tasks-list-creator
implement-tasks             → implementer
verify-implementation       → implementation-verifier
```

### All Standards Usage
```
Global standards:    Referenced by all commands
Backend standards:   For API/database work
Frontend standards:  For UI/component work
Testing standards:   For test writing tasks
```
