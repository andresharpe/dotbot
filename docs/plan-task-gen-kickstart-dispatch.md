# Fix Plan: `task_gen` Dispatch in Kickstart Engine

**Issue:** #256 — Phase 4 (Plan Atlassian Research) falls through to generic LLM handler, Claude does research instead of creating task files, wastes ~$4/run.

---

## Root Cause

`Invoke-KickstartProcess.ps1` generic LLM handler injects an instruction telling Claude _not_ to create tasks. `task_gen` phases land in this same handler, so that instruction directly contradicts the prompt's guidance to call `task_create`. Claude resolves the conflict by doing the research itself. No dedicated `task_gen` dispatch branch exists — the phase type is silently ignored.

---

## Steps

### Step 1 — Add a dedicated `task_gen` dispatch branch

In `Invoke-KickstartProcess.ps1`, add a new handler branch for `task_gen` phases before the generic LLM fallback. This handler runs the same `.md` workflow prompt but replaces the "do not create tasks" instruction with the opposite: create tasks via `task_create` and do nothing else. It also validates `min_output_count` after the LLM run, failing fast if no task files were produced.

### Step 2 — Harden the three `task_gen` prompts

Add a prominent "TASK GENERATION ONLY" notice at the top of `02a-plan-internet-research.md`, `02b-plan-atlassian-research.md`, and `02c-plan-sourcebot-research.md`. Defense-in-depth: even if dispatch is misconfigured, the prompt constraint fires first.

### Step 3 — Run tests

Run layers 1-3. If Layer 3 mock workflow has no `task_gen` phase, add a minimal fixture phase to exercise the new branch.

---

## Files Changed

| File | Change |
|------|--------|
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-KickstartProcess.ps1` | Add `task_gen` dispatch branch with output validation |
| `workflows/kickstart-via-jira/recipes/prompts/02a-plan-internet-research.md` | Add TASK GENERATION ONLY banner |
| `workflows/kickstart-via-jira/recipes/prompts/02b-plan-atlassian-research.md` | Add TASK GENERATION ONLY banner |
| `workflows/kickstart-via-jira/recipes/prompts/02c-plan-sourcebot-research.md` | Add TASK GENERATION ONLY banner |

---

## Acceptance Criteria

- [ ] Phase 4 creates ≥1 file in `tasks/todo/` — `min_output_count` validation passes
- [ ] Claude does not edit spec documents during `task_gen` phases
- [ ] API spend for a `task_gen` phase is minimal (one `task_create` call, no research loop)
- [ ] Layers 1-3 tests pass

---

## Out of Scope

- `New-WorkflowTask` / `workflow-manifest.ps1` conversion path — not called by kickstart engine
- Other `task_gen` callers outside kickstart — none found