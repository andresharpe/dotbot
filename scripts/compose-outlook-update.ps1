$ErrorActionPreference = "Stop"

try {
    $outlook = [Runtime.InteropServices.Marshal]::GetActiveObject("Outlook.Application")
} catch {
    $outlook = New-Object -ComObject Outlook.Application
}

$mail = $outlook.CreateItem(0)
$mail.To = "erol.karabeg@authoritypartners.com; Carlos.Pedreira@iwgplc.com; Can.Bilgin@authoritypartners.com"
$mail.Subject = "Dotbot v3 — PR #62 merged + decision tracking update"
$mail.Body = @"
Hi Erol, Carlos, Can,

Quick update on dotbot v3 refactor progress:

1) PR #62 merged to main (Decision Records / Phase 5)
- PR #62 (Add ADR management functionality) is now merged to main.
- Delivery is ~90% aligned with the roadmap spec.
- Implemented: decision tools, Decisions dashboard tab, workflow integration, task integration, and tests.

What was delivered:
- 7 MCP tools: decision-create, decision-get, decision-list, decision-update, decision-mark-accepted, decision-mark-deprecated, decision-mark-superseded
- Decisions UI tab with create/edit/status-change flows
- Kickstart workflow step to generate decisions from interview + product docs
- Task analysis/execution now consume decision constraints
- Comprehensive test coverage for decision tooling

Remaining documented gaps:
- No standalone decision-link tool yet (linking currently handled through decision-update)
- Event bus emission for decision events deferred until Phase 4
- Init-time directory creation differs from spec (profile template gitkeep dirs used)

2) Gap closure completed on main: per-task clarification decision tracking
- We identified a gap where per-task clarification answers could remain trapped in a single task context.
- Fixed on main via prompt update to 98-analyse-task.md:
  - After clarification answers, agents now evaluate if the answer is a reusable architectural decision.
  - If yes, they create a decision (tag: task-derived) and link it to the originating task.
- This was a prompt-level fix (no tooling/code changes required).

3) Planning/docs branch status
- Planning branch was rebased and roadmap docs were updated to reflect Phase 5 as substantially complete.
- Gaps and follow-up items are documented clearly.

Happy to walk through details if useful.

Regards,
Andre
"@

$mail.Display()
Start-Sleep -Seconds 1
Write-Output "Outlook draft opened successfully"
