# Dotbot v4 — Design Ideas

| Field | Value |
|---|---|
| **Date** | 2026-04-19 |
| **Author** | André Sharpe |
| **Status** | DRAFT — ideas and direction, not an ADR or execution plan |
| **Companion to** | [`UI-AND-DOMAIN-MODEL-WHITEPAPER-v2.md`](whitepapers/UI-AND-DOMAIN-MODEL-WHITEPAPER-v2.md), [`design-system` skill](../.claude/skills/design-system/SKILL.md) |

---

## 1. Why this document exists

The v2 whitepaper locks the **architecture** (Mothership / Outpost / Drone / Studio) and commits to "full CRT everywhere" via shared tokens. It does not yet reconcile three design pressures that have surfaced since:

1. **Too many surfaces.** Dotbot Studio — the workflow/recipe/tool editor formerly called "Workflow Editor" — currently lives as a third React app on its own port. We should question that.
2. **A newer tonal reference.** The [`dotbot.ch`](https://dotbot.ch) landing page layers a **dispatch / telegraph / Morse** motif on top of the CRT base: serial numbers (`DB-DLT07EMU18FNV29G`), build stamps (`2026.04.12 // STABLE`), signed dispatches from a narrator called **Morse**.
3. **A wider audience.** v4 must be usable by non-technical stakeholders — PMs, approvers, business reviewers answering questions via Outpost — without losing the operator cockpit that developers rely on. Today's Outpost is a dense 9–11px mono control surface. That excludes half the audience.

This doc is **design direction**, not decisions. It proposes; it flags; it recommends. Anything controversial is called out.

---

## 2. The dual-persona problem

Every surface in dotbot has two real users:

- **Operator** — a developer steering processes, reading logs, debugging workflows. Keyboard-first. Lives in the palette. Wants density and control.
- **Stakeholder** — a PM, approver, business reviewer, designer. Clicks a notification link, scans, decides. Wants clarity and calm. Intimidated by serial numbers and 9px labels.

Today's Outpost is built for operators. Today's Mothership `/Respond` form is built for stakeholders — and (not coincidentally) it's the most cohesive surface in the system.

**Design principle:** *every surface has an operator layer and a stakeholder layer.* The stakeholder layer is the default; the operator layer is a keyboard-accessible overlay (command palette, dense mode toggle, raw log panes). The CRT identity persists in both.

> **Rule of thumb:** if a non-technical user can't get the gist of a screen in 10 seconds without help, the default layout is wrong — not the user.

---

## 3. Current state — an honest audit

### 3.1 Outpost (`workflows/default/systems/ui/static/`)

What works:

- Strong, recognisable CRT identity — amber phosphor, scanlines, LED indicators, dual-scale grid
- Coherent token system (`theme.css`, 6 presets, RGB-componented for opacity compositing)
- Keyboard-friendly density for developers

What reads as dated:

- **Density tax.** 13px base, 9–10px labels, 280px sidebar + top-tab row. Every screen has too many moving parts in view at once.
- **Engineer voice.** Copy is terse to the point of hostile: "PROC", "IDX", status names that assume the mental model.
- **Mobile cramped.** Hamburger + full-width tabs + dense content = unusable on phones.
- **Grid fatigue.** The dual-scale grid at 8% opacity reads as visual noise on wide screens.
- **Legacy aliases.** Mix of `--phosphor-amber` / `--color-primary`, `--amber-10` / `--primary-10` still in flight per the design-system checklist.

### 3.2 Mothership (`server/src/Dotbot.Server/`)

What works:

- Same tokens as Outpost — visual kinship is real
- `/Respond` is genuinely good: single-task focus, centered card, generous padding, larger type, friendlier copy. This is the template.

What reads as dated:

- **Admin-CRUD layout.** The Overview / By Person / By Project split panel feels like Jira's people directory, not a command centre.
- **Less identity than Outpost.** Takes the CRT tokens but not the CRT attitude. The glow is dialled down; the grid is subtler; the LEDs are smaller. It looks *correct* but doesn't look like *dotbot*.
- **No shared shell.** Header markup is duplicated between the two Razor pages and again in Outpost; diverges subtly each time.

### 3.3 Studio (`studio-ui/`)

What works:

- React Flow is the right canvas for DAG editing. Not negotiable.

What reads as dated (within months of being built):

- **Off-brand slate theme.** Doesn't look like dotbot at all. The whitepaper already calls this out.
- **Separate port / separate URL.** One more "which one was it again?" moment for the user.
- **Audience is operator-only.** A PM has no business opening Studio. That's fine — it just shouldn't be on the main map.

### 3.4 Key insight

> The only dotbot surface all audiences touch today is the Mothership `/Respond` form. It's the calmest, most generous, most on-brand page we ship. **v4 should learn from `/Respond`, not from the Outpost cockpit.**

---

## 4. The `dotbot.ch` signal

The landing page is the brand's most recent self-portrait. It's worth treating as intentional.

### 4.1 What it does

- Keeps the CRT base (dark backgrounds, monospace, terminal voice)
- Layers on a **dispatch / telegraph** vocabulary:
  - Serial numbers as structural furniture: `DB-DLT07EMU18FNV29G`
  - Build stamps with channel: `2026.04.12 // STABLE`
  - A signed dispatch column: "Dispatches from Morse" — dated entries signed `— Morse · stop`
  - Classification-adjacent framing (not literal "TOP SECRET" costume, but the cadence of a restricted broadcast)
- Oscillates copy between terse CLI (`stop prompting. Orchestrate.`) and theatrical dispatch ("The Missing Layer Between AI And Your Codebase")

### 4.2 How it translates into the app — medium lean

Use dispatch voice for the **world**. Keep plain voice for the **work**.

| Where dispatch voice belongs | Where it does not |
|---|---|
| Event log / process feed | Task titles |
| Empty states ("no transmissions. standing by.") | Question text shown to recipients |
| Release notes inside the app | Error messages |
| Section dividers, footers, tickers | Onboarding copy |
| Status broadcasts on the Mothership home | Settings labels |

If a non-technical user will read it as part of doing their job, it's plain. If it's furniture, it's dispatch.

### 4.3 Who is Morse?

Open question. Is Morse a persistent narrator character (byline on all dispatches, recognisable voice)? Or just a copy style? Recommendation: **Morse is a byline, not a mascot.** Every dispatch-voiced string ends `— M` or `· stop`. No avatar, no backstory, no personality page. The voice exists; the character doesn't.

---

## 5. Design principles for v4

1. **Retro-futuristic, not retro-technical.** Keep scanlines, phosphor, deep blacks, amber/cyan. Drop the visual density that reads as "sysadmin console". *Because* the audience is wider than the engineer who built it.

2. **Breathing room is a feature.** Raise the stakeholder base type from 13→14px. Increase stat card padding. Cap content width at ~1280px on wide screens. Dim the dual-scale grid on content areas from 8% to 4–5%. *Because* density kills stakeholder adoption, and the CRT identity survives a 25% drop in visual noise.

3. **Two type defaults, honestly picked.** Mono (JetBrains Mono) for data, values, controls, timestamps, status codes. UI sans (Inter) for prose, descriptions, task titles, anything a stakeholder reads. Today's mix is right in theory, inconsistent in practice. *Because* codifying it once saves a hundred judgment calls.

4. **Morse as furniture, not content.** Dispatch language lives in frames, tickers, empty states, headers, footers. Never in task text or recipient-facing copy. *Because* flavour that interrupts work stops being flavour.

5. **Status via colour + shape + word.** Every status indicator pairs a colour with an icon *and* a labelled word. No more "you just have to know amber = todo and cyan = in-progress." *Because* colour-only signals fail for colour-blind users, non-technical users, and skim readers — three audiences we explicitly serve.

6. **Command palette is the operator layer.** `Ctrl/Cmd-K` opens a dispatch-styled palette with fuzzy search across tasks, decisions, people, projects, settings, actions. *Because* the power-user density belongs behind a shortcut, not in the default layout.

7. **One shell, many rooms.** Mothership and Outpost share a single shell — header, left rail, palette, ticker — rendered from a new `shared/css/dotbot-shell.css` that sits alongside `dotbot-tokens.css` and `dotbot-crt.css`. *Because* the kinship is a product promise; diverging shells break it quietly.

---

## 6. Surface consolidation — Studio into Mothership

### 6.1 Proposal

Studio stops being a separate app. It becomes a **tab inside Mothership**, embedded as a React island inside the Razor shell.

Mothership surfaces become:

```
Fleet · Decisions · Studio · People · Settings
```

Outpost gets an **"Edit workflow"** button that deep-links to `mothership://studio/workflows/<name>`, opening Studio in a new browser tab when Mothership is configured.

### 6.2 Trade-offs

| Pro | Con |
|---|---|
| One less server, one less port, one less URL to remember | Bigger Mothership bundle; React-in-Razor needs care |
| Studio gets the CRT treatment "for free" from the shared shell | Studio's audience is technical only — putting it next to Fleet and Decisions blurs Mothership's audience |
| Cross-surface links stop being "open yet another tab" | Deployment story changes (one app to ship, not two) |
| One team owns the shell | React Flow inside Razor needs a clean island pattern |

### 6.3 Recommendation

**Consolidate.** Use the left rail's grouping (operate surfaces above a divider, author surfaces below) to manage the audience blur visually. Non-technical users simply never click the "author" group — same way they don't open `.bot/settings/`.

This is the single biggest open question in this doc. If we keep Studio separate, everything else still stands — the navigation model, the shell, the dispatch motif. But the "too many surfaces" problem returns.

---

## 7. Navigation — one shell, two rooms

### 7.1 Today's model

- Top bar (60px)
- Tab row directly below header
- Left sidebar (280px, context-dependent contents)
- Right content
- No footer of note

Dense, functional, unmistakably a power tool.

### 7.2 Proposed v4 shell

```
┌───────────────────────────────────────────────────────────────┐
│ ◈ DOTBOT   project/fleet context ▾    [ ⌘K  search ]   ● ● ●  │   top bar (44px)
├────┬──────────────────────────────────────────────────────────┤
│ □  │                                                           │
│ ▣  │                                                           │
│ ◇  │                                                           │
│    │                    main content                           │
│ ○  │              (capped at ~1280px width,                    │   rail (56px)
│ ◆  │               generous padding, calm grid)                │   icon-only,
│    │                                                           │   labeled on hover
│ ─  │                                                           │   or pin
│ ⚙  │                                                           │
├────┴──────────────────────────────────────────────────────────┤
│ DISPATCH · 03 · 2026-04-19T14:22Z · all systems nominal   — M │   ticker (28px)
└───────────────────────────────────────────────────────────────┘
```

### 7.3 Components

**Top bar (44px).** Logo, context picker (project name / fleet name / current workflow), palette trigger (visible as a search pill — see §7.4), three LEDs kept from today (connection, running, signal). The LEDs now always pair with tooltips carrying a labelled word.

**Left rail (56px).** Icon-only primary navigation; hover reveals a tooltip label; users can pin the rail open to 200px for labelled mode. Groups separated by a thin bezel divider — e.g. Mothership has an "operate" group (Fleet, Decisions, People) above the divider and an "author" group (Studio, Settings) below. Replaces both today's top tabs and today's contextual sidebar.

**Main content.** Full available width up to ~1280px, then capped and centred. Module panels keep bezel + screen treatment but with dimmer grid (4–5% opacity) and more generous internal padding. Content hierarchy is clearer because the rail has taken the "where am I?" load off the page itself.

**Dispatch ticker (28px, footer).** Scrolls the latest N events/decisions/processes in dispatch voice. Optional per-surface (§12). This is where the Morse layer lives without invading content. Pausable on hover, slow by default (≥20s full cycle), respects `prefers-reduced-motion`.

**Command palette (`⌘K`).** Full-width dispatch-styled overlay. Fuzzy search across every object in the current surface's scope: tasks, decisions, people, projects, settings, actions ("start analysis on task X", "open workflow editor for default"). Visible search pill in the top bar is the affordance for users who don't know the shortcut exists.

### 7.4 Why this works for both personas

- **Stakeholders** see a calm, iconographic layout with labelled status, generous padding, and plain copy. They never need to see the palette.
- **Operators** press `⌘K` and live there. They pin the rail closed for maximum canvas. They read the ticker out of the corner of their eye.
- **Dispatch flavour** has a home (ticker, empty states, footers) that never blocks work.
- **The shell is identical** across Mothership and Outpost, so muscle memory transfers.

---

## 8. Mothership v4 — surfaces

Within the shell above, Mothership routes to:

| Rail icon | Surface | Purpose |
|---|---|---|
| □ | **Fleet** | Registered outposts + drones, heartbeats, telemetry, "who's working on what right now" |
| ▣ | **Decisions** | Cross-outpost decisions + Q&A. Absorbs today's Overview / By Person / By Project into one surface with filter chips instead of sub-tabs |
| ◇ | **Studio** | Workflow + recipe + tool editor. React Flow canvas in CRT livery. Below the "operate / author" divider |
| ○ | **People** | Directory of humans, roles, accountability paths (per whitepaper §2) |
| ⚙ | **Settings** | Fleet config, theme, auth. Below the divider |

**Fleet is the new home.** Landing on Mothership today drops you on a Q&A dashboard that conflates "what needs my attention" with "what is the system doing". v4 separates those: Fleet answers "what is the system doing", Decisions answers "what needs my attention".

**Ticker content on Mothership:** fleet-wide dispatch. "Outpost alpha picked up task T-042 · Drone sigma finished migration worktree · Decision dec-17 escalated to andre".

---

## 9. Outpost v4 — surfaces

| Rail icon | Surface | Purpose |
|---|---|---|
| □ | **Overview** | The cockpit. Current task, running processes, session + git status, panic button. Home. |
| ▣ | **Tasks** | Backlog + lifecycle. Combines today's Overview stats grid and Processes list into one surface with status filter chips |
| ◆ | **Product** | Product docs, roadmap. Rethinks density for stakeholder readers — this is the most-read stakeholder surface in Outpost |
| ◇ | **Decisions** | Per-project decisions, linked to Mothership |
| ○ | **Workflow** | Read-only view of the current workflow definition + "Open in Studio" deep-link (see §6) |
| ⚙ | **Settings** | Project config, theme, mothership URL |

**Tasks collapses three things that are really one thing.** Today Overview shows stat counts, Processes shows running processes, and the task backlog is split across modal detail views. v4 merges them: Tasks is a single list with filter chips for state (todo / analysing / analysed / in-progress / done) and a slim right panel for selected-task detail.

**Ticker content on Outpost:** project dispatch. "Task T-042 moved to analysed · Process P-09 started · Whisper received from operator · Commit [task:abcd1234] pushed to main".

---

## 10. Component-level evolution notes

Each change is a nudge, not a rewrite. The design-system skill stays authoritative for tokens and patterns; this section notes where v4 should push against existing rules.

- **Stat cards.** Keep phosphor glow on the value. Raise internal padding (14px 16px → 20px 24px). Drop the per-card grid overlay — the shell carries texture now. *Because* stacking grid on grid on grid is what makes the current dashboard feel busy.

- **Task rows.** Keep 3px left-border status accent. Raise vertical rhythm (10–12px → 14–16px). Pair colour with a short labelled word (`TODO`, `ANALYSING`, `DONE`). *Because* status is the most-read signal in the app; invest in it.

- **Module panels.** Keep bezel + screen structure. Soften grid from 8% to 4–5% opacity. Raise screen padding (14–16px → 20–24px). *Because* the panel edges already give enough "hardware" feel; the grid can relax.

- **Buttons.** Keep mono / uppercase / 0.05em letter-spacing / `translateY(1px)` press. Introduce a **text button** variant for stakeholder contexts: sentence case, Inter, no uppercase, no letter-spacing. *Because* "CONFIRM" shouted at a non-technical user feels like a warning; "Confirm" reads as a button.

- **Empty states.** Every single one gets a dispatch-voice line. This is the single most charming place to put the Morse flavour: "no transmissions. standing by. — M"; "queue is quiet. awaiting dispatch. — M"; "no decisions in flight. all clear. — M". *Because* empty states are the most-seen and least-designed part of any app; making them the Morse signature is cheap and durable.

- **Modals.** Cap stakeholder-facing modals at 720px; operator-detail modals at 900px. Stakeholder modals use sentence case and Inter. *Because* the modal is where stakeholders actually read prose — 900px of 11px mono is a wall.

- **LEDs.** Keep the 8px glowing circle. Always pair with a tooltip carrying a labelled word. Consider a second "calm" variant (no glow, no animation) for ambient status that shouldn't demand attention. *Because* three pulsing lights in the header trains users to ignore them.

- **Tabs (where they still exist inside a surface — e.g. Decisions filter chips).** Replace `0.08em` uppercase tabs with sentence-case filter chips. *Because* uppercase tabs read as section headers; filter chips read as "choose one", which is what they actually are.

---

## 11. Motion and effects

- **Scanlines.** Keep. Make intensity a theme variable: 6% on the shell (header, rail, ticker, empty canvas), 0% on content panels. *Because* the identity is protected by the shell texture; content doesn't need to fight it.
- **Phosphor glow.** Keep on stat values and status words. Remove ambient glow from body text — it hurts readability at 14px. *Because* glow is a signal, and signals lose meaning when everything glows.
- **CRT flicker on surface change.** New: a 120ms brightness dip when switching surfaces, as a navigation cue. Subtle, one frame of warm-up. *Because* the current UI is visually static between surfaces; a tiny flicker anchors the CRT metaphor.
- **Ticker scroll.** ≥20s full cycle. Pausable on hover. Stops on focus. Respects `prefers-reduced-motion` (no scroll — latest item shown static).
- **All animation.** Respect `prefers-reduced-motion` across the board: no scanlines flicker, no ticker scroll, no LED pulse. Keep the colour and the shape; drop the movement.

---

## 12. Open questions

These are the calls we have not yet made. Flagging them here so the doc is honest about what's decided vs what's open.

1. **Studio consolidation.** Does Studio actually fold into Mothership, or stay separate on its own port? *Recommendation: fold. Flag audience-blur as the main risk.*
2. **Stakeholder type base.** 14px Inter body + 12px mono data — or 13px across the board? *Recommendation: 14/12 split on stakeholder surfaces; 13/11 on operator surfaces.*
3. **Ticker ubiquity.** Does Outpost also get a dispatch ticker, or is that a Mothership-only signature? *Recommendation: both, but Outpost ticker defaults collapsed and opens on click.*
4. **Morse as voice.** Persistent narrator character, or copy style only? *Recommendation: byline, not mascot. Every dispatch-voice string ends `— M` or `· stop`. No character page.*
5. **Command palette discoverability.** How do non-technical users find `⌘K`? *Recommendation: pinned search pill in the top bar is the visible affordance; the shortcut is for operators.*
6. **Theme presets.** Six CRT presets (amber / cyan / green / blue / purple / white) — is that still the right range, or is amber-as-default + one alternate enough? *Recommendation: keep amber as default, promote cyan as the "calm" alternate, demote the others to a hidden "classics" toggle.*
7. **Reduced-motion defaults.** Should reduced-motion be the *default* and full-motion opt-in? *Recommendation: no — full-motion is the product identity — but respect the OS flag rigorously.*

---

## 13. Next steps (after this doc lands)

Not the scope of this doc, but the obvious follow-ups:

- Draft short ADRs for the three biggest calls: **(a)** Studio consolidation, **(b)** dual type base, **(c)** command palette as the operator layer.
- Spike `shared/css/dotbot-shell.css` as a standalone token demo rendered by a tiny HTML harness — no dotbot runtime needed to review the look.
- Prototype the dispatch ticker against real process events from the Outpost event bus.
- Accessibility pass: colour-only status signals, labelled words beside LEDs, palette keyboard trap behaviour, reduced-motion coverage.
- Usability test the stakeholder flow (`/Respond` → Decisions in Outpost → approval loop) with one non-technical user, unguided. Everything else is theory until then.

---

## Appendix A — Quick reference: what changes, what doesn't

| Area | v3 today | v4 proposal |
|---|---|---|
| Identity | Amber CRT | Amber CRT + dispatch furniture |
| Default type base | 13px mono everywhere | 14px Inter (stakeholder) / 13px mono (operator) |
| Navigation | Top tabs + 280px contextual sidebar | Top bar + 56px icon rail + palette |
| Surface count | Mothership + Outpost + Studio (3 apps) | Mothership (absorbs Studio) + Outpost (2 apps) |
| Grid intensity | 8% on content | 6% on shell, 4–5% on content |
| Status signalling | Colour + shape | Colour + shape + labelled word |
| Empty states | Generic | Morse dispatch |
| Footer | 36px with build info | 28px dispatch ticker (+ build info in palette) |
| Command palette | None | `⌘K`, dispatch-styled, fleet-wide scope on Mothership / project-wide on Outpost |
| Theme presets | 6 on equal footing | Amber default, cyan "calm", classics behind a toggle |

## Appendix B — Referenced material

- [`UI-AND-DOMAIN-MODEL-WHITEPAPER-v2.md`](whitepapers/UI-AND-DOMAIN-MODEL-WHITEPAPER-v2.md) — architecture, three-tier model, shared tokens
- [`.claude/skills/design-system/SKILL.md`](../.claude/skills/design-system/SKILL.md) — tokens, components, anti-patterns, checklist
- `workflows/default/systems/ui/static/` — Outpost source
- `server/src/Dotbot.Server/` — Mothership source
- `studio-ui/` — Studio source
- `shared/css/dotbot-tokens.css` — shared token file (emerging)
- `dotbot.ch` — current public landing, source of the dispatch/Morse motif

— M · stop
