# Phase 9: Additional Improvements

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## 9a. Health Check System
- `scripts/doctor.ps1` — directories, orphaned worktrees, stuck tasks, dead PIDs, CLI availability
- `systems/ui/modules/HealthAPI.psm1`

## 9b. Process Telemetry
- `systems/runtime/modules/Telemetry.psm1` — per-task metrics
- `.bot/.control/telemetry/` as JSONL
- Emits events via bus

## 9c. Idempotent Init
- `dotbot init` works without `--force` — detects state, updates only newer files, preserves workspace

## 9d. Configuration Validation
- `systems/runtime/modules/ConfigValidator.psm1` — schema validation for settings, workflow.yaml, task JSON
