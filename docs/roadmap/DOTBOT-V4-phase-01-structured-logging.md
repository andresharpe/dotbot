# Phase 1: Structured Logging Module (Foundation)

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

**Why first:** Every subsequent phase benefits from proper logging.

## Create `DotBotLog.psm1`
- **Path:** `profiles/default/systems/runtime/modules/DotBotLog.psm1`
- Functions:
  - `Write-BotLog -Level {Debug|Info|Warn|Error|Fatal} -Message <string> -Context <hashtable> -Exception <ErrorRecord>`
  - `Initialize-DotBotLog -LogDir <path> -MinLevel <level>`
  - `Rotate-DotBotLog` — removes files older than 7 days
- Output: structured JSONL to `.bot/.control/logs/dotbot-{date}.jsonl`
- Each line: `{ts, level, msg, process_id, task_id, phase, pid, error, stack}`
- Activity log integration: Info+ events also go to `activity.jsonl` for backward compat
- `Write-Diag` becomes a thin wrapper: `Write-BotLog -Level Debug`
- `Write-ActivityLog` delegates internally to `Write-BotLog`

## Settings addition
```json
"logging": {
  "console_level": "Info",
  "file_level": "Debug",
  "retention_days": 7,
  "max_file_size_mb": 50
}
```

## Replace silent catch blocks
All 25+ `catch {}` blocks become:
```powershell
catch { Write-BotLog -Level Warn -Message "..." -Exception $_ }
```

## Files
- Create: `profiles/default/systems/runtime/modules/DotBotLog.psm1`
- Modify: `profiles/default/defaults/settings.default.json`
- Modify: `profiles/default/systems/runtime/launch-process.ps1`
- Modify: `profiles/default/systems/runtime/modules/ui-rendering.ps1`
- Add to init: `.bot/.control/logs/`
