# OpenClaw Channel Research

Surveys the messaging channels documented at OpenClaw's channels page,
evaluates each one for dotbot's "orchestrate humans" use case (asking
questions, getting approvals, sending status updates), assesses the
integration effort to add each channel directly as a dotbot delivery
provider (`IQuestionDeliveryProvider`), and ranks the channels to
prioritise next.

> **Scope note.** OpenClaw is itself an AI agent runtime, not a messaging
> channel. This document uses its channels page only as a convenient
> market catalogue of chat platforms. Whether dotbot should integrate
> with OpenClaw as a system is outside the scope of Issue #38.

---

## 1. Channel catalogue

Source: <https://docs.openclaw.ai/channels>. Most channels have a dedicated
docs page at `/channels/<name>`; Voice Call lives at `/plugins/voice-call`
and WebChat at `/web/webchat`. The catalogue lists 25 chat channels
(alphabetical):

1. **Discord**: Bot API + Gateway; supports servers, channels, and DMs.
2. **Feishu (Lark)**: Feishu/Lark bot via WebSocket (bundled plugin).
3. **Google Chat**: Google Chat API app via HTTP webhook (downloadable
   plugin).
4. **iMessage**: Native macOS integration via the `imsg` bridge on a
   signed-in Mac (or SSH wrapper when the Gateway runs elsewhere); supports
   private API actions.
5. **IRC**: Classic IRC servers; channels and DMs with pairing / allowlist
   controls.
6. **LINE**: LINE Messaging API bot (downloadable plugin).
7. **Matrix**: Matrix protocol (downloadable plugin).
8. **Mattermost**: Bot API + WebSocket; channels, groups, DMs (downloadable
   plugin).
9. **Microsoft Teams**: Bot Framework; enterprise support (bundled plugin).
10. **Nextcloud Talk**: Self-hosted chat via Nextcloud Talk (bundled
    plugin).
11. **Nostr**: Decentralised DMs via NIP-04 (bundled plugin).
12. **QQ Bot**: QQ Bot API; private chat, group chat, and rich media
    (bundled plugin).
13. **Signal**: signal-cli; privacy-focused.
14. **Slack**: Bolt SDK; workspace apps.
15. **Synology Chat**: Synology NAS Chat via outgoing + incoming webhooks
    (bundled plugin).
16. **Telegram**: Bot API via grammY; supports groups. Upstream notes this
    as the fastest setup (bot token only).
17. **Tlon**: Urbit-based messenger (bundled plugin).
18. **Twitch**: Twitch chat via IRC connection (bundled plugin).
19. **Voice Call**: Telephony via Plivo or Twilio (plugin, installed
    separately).
20. **WebChat**: OpenClaw's bundled Gateway WebChat UI over WebSocket.
21. **WeChat**: Tencent iLink Bot plugin via QR login; private chats only
    (external plugin).
22. **WhatsApp**: Uses Baileys, requires QR pairing, state stored on disk.
    Upstream calls this the most popular channel.
23. **Yuanbao**: Tencent Yuanbao bot (external plugin).
24. **Zalo**: Zalo Bot API; Vietnam's popular messenger (bundled plugin).
25. **Zalo Personal**: Zalo personal account via QR login (bundled plugin).

---

## 2. Per-channel evaluation and integration effort

Each row evaluates the channel for dotbot's orchestration pattern (asking
N humans a question, collecting their answer or approval) and assesses
the direct integration effort to add a new `IQuestionDeliveryProvider`
that talks to the channel's first-party APIs (not OpenClaw's pipeline).

Effort scale: **S** (about a day), **M** (a few days), **L** (about a
week). Fit scale: **high** (clear orchestration fit), **medium** (works,
narrower audience), **low** (works but constrained), **skip** (does not
fit the use case).

| Channel         | Fit               | Interactive controls                                                       | Direct integration path                                                                                           | Effort | Notes                                                                                                    |
| --------------- | ----------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------- |
| Discord         | high              | buttons, select menus, modals (Components V2)                              | Bot + Interactions endpoint, `Discord.Net` for the C# server                                                      | M      | already in Phase 13 scope; large active community user base                                              |
| Feishu (Lark)   | medium            | interactive cards, approval flows                                          | Feishu/Lark Open Platform Bot APIs                                                                                | M      | strong in Greater China and pan-Asia enterprise                                                          |
| Google Chat     | high              | Card v2, dialogs, buttons                                                  | Google Chat API (service account + OAuth)                                                                         | M      | symmetric to Teams for Google Workspace customers                                                        |
| iMessage        | low               | basic text; rich controls only via Messages for Business                   | Apple Messages for Business via an approved CSP                                                                   | L      | Apple approval gate is selective and slow; consumer leaning                                              |
| IRC             | skip              | none (plain text)                                                          | direct IRC client library                                                                                         | S      | no buttons or cards; poor orchestration UX                                                               |
| LINE            | medium            | quick replies, flex messages, rich menus                                   | LINE Messaging API (Official Account)                                                                             | M      | dominant in Japan, Taiwan, Thailand                                                                      |
| Matrix          | medium            | reactions, threads, replies (client-rendered)                              | `matrix-bot-sdk` or similar                                                                                       | M      | privacy-sensitive and federation-friendly orgs                                                           |
| Mattermost      | medium            | interactive messages, slash commands, ephemeral updates                    | Mattermost REST + WebSocket                                                                                       | M      | self-hosted Slack alternative; fits orgs that cannot use SaaS chat                                       |
| Microsoft Teams | already a channel | Adaptive Cards                                                             | already implemented (`TeamsDeliveryProvider`)                                                                     | n/a    | shipped                                                                                                  |
| Nextcloud Talk  | low               | slash commands, plain text; no rich cards                                  | Nextcloud Talk OCS API                                                                                            | M      | niche user base; weak interactive surface                                                                |
| Nostr           | skip              | encrypted DMs, no native buttons                                           | Nostr relay + NIP-04 client                                                                                       | S-M    | decentralised DM protocol; not orchestration-shaped                                                      |
| QQ Bot          | low               | rich media, custom keyboards                                               | QQ Open Platform Bot API                                                                                          | M      | China-only; addressable base outside Greater China negligible                                            |
| Signal          | low               | text and reactions only; no native buttons                                 | `signal-cli` or `signald` REST wrapper                                                                            | M      | weak bot tooling; per-installation phone number constraint                                               |
| Slack           | already a channel | Block Kit                                                                  | already implemented (`SlackDeliveryProvider`, PR #84)                                                             | n/a    | shipped                                                                                                  |
| Synology Chat   | skip              | incoming / outgoing webhooks only                                          | Synology Chat webhook API                                                                                         | S      | tied to Synology NAS estate; tiny addressable base                                                       |
| Telegram        | high              | inline keyboards, callback buttons, polls                                  | Bot API (single bot token; signing not required)                                                                  | S      | fastest single-channel integration; strong fit for cross-org and informal teams                          |
| Tlon            | skip              | basic chat                                                                 | Urbit / Tlon SDK                                                                                                  | L      | Urbit ecosystem; tiny user base                                                                          |
| Twitch          | skip              | chat commands, bits                                                        | Twitch IRC / EventSub                                                                                             | M      | live-stream chat; wrong category for orchestration                                                       |
| Voice Call      | low               | DTMF / TTS prompts                                                         | Twilio Voice or Plivo Voice                                                                                       | M      | telephony, not chat; useful only as an escalation channel                                                |
| WebChat         | skip              | n/a (OpenClaw's own browser UI)                                            | n/a                                                                                                               | n/a    | not an external destination; dotbot already has its own web form in Phase 13                             |
| WeChat          | low               | rich messages, approvals (WeChat Work); consumer WeChat heavily restricted | WeChat Work API or Official Account API                                                                           | L      | strong fit for Chinese enterprise; high integration cost; consumer WeChat constrained                    |
| WhatsApp        | high              | list pickers, up to three quick-reply buttons, CTA URL, flow templates     | **WhatsApp Cloud API (Meta) directly, or via a BSP such as Twilio / Infobip; do not use OpenClaw's Baileys path** | M-L    | already in Phase 13 scope; widest external-recipient reach; Baileys / WAHA / Wppconnect violate Meta ToS |
| Yuanbao         | skip              | unknown                                                                    | Tencent Yuanbao bot API                                                                                           | M      | Chinese AI-assistant ecosystem; no business orchestration use case identified                            |
| Zalo            | skip              | basic templates                                                            | Zalo Official Account API                                                                                         | M      | Vietnam-only consumer messenger; narrow base                                                             |
| Zalo Personal   | skip              | none (personal account)                                                    | reverse-engineered Zalo client                                                                                    | n/a    | personal-account scraping; ToS risk; same geo as Zalo OA                                                 |

---

## 3. Priority recommendation

Ranking of the channels dotbot should add next as direct delivery
providers. The current channels are Teams, Email, Jira, and Slack. The
Phase 13 roadmap (`docs/roadmap/DOTBOT-V4-phase-13-multi-channel-qa.md`)
already names **Discord**, **WhatsApp**, and **Web** as the next channels;
this ranking confirms and refines that list.

### P1: add next (Phase 13)

1. **Discord.** Best ROI. Large active user base in product, engineering,
   and community orgs. Components V2 covers approvals (buttons), free
   text (modals), and multi-choice (select menus) natively. Conventional
   integration is Bot + Interactions endpoint with Ed25519 signature
   verification on inbound interactions. Already in Phase 13 scope.

2. **WhatsApp (via Meta Cloud API).** Widest external-recipient reach of
   any chat channel. Cloud API supports list pickers and up to three
   quick-reply buttons, plus approved templates for outbound after the
   24-hour conversation window. Must use the Cloud API directly or via a
   Business Solution Provider (Twilio, Infobip, MessageBird, Vonage).
   Avoid Baileys / WAHA / Wppconnect: they reverse-engineer WhatsApp Web
   and violate Meta's terms; numbers risk being banned. Already in
   Phase 13 scope.

3. **Telegram.** Fastest integration of any new channel: one bot token,
   no signing secret, no app approval. Strong fit for cross-org and
   informal teams. Inline keyboards and callback buttons map directly to
   approvals and single-choice questions; polls map to multi-choice.
   Worth adding even though Phase 13 does not yet name it.

### P2: add when target customer demand materialises

4. **Google Chat.** Symmetric to Teams: fits Google Workspace customers
   the way Teams fits M365 customers. Cards V2 covers approvals and
   dialogs. Required if dotbot wants to be the obvious orchestration
   tool in a non-M365 enterprise estate.

5. **Mattermost.** Self-hosted Slack alternative. Adds the orgs that
   will not use SaaS chat (regulated industries, gov, on-prem-only
   estates).

6. **Matrix.** Open federated protocol. Adds privacy-sensitive and
   federation-friendly customers. Bot SDKs handle reactions, threads,
   and replies; richer interactive controls are client-dependent.

### P3: region-specific; defer until demand

7. **LINE.** Japan, Taiwan, Thailand.
8. **Feishu / Lark.** Greater China and pan-Asia enterprise.
9. **WeChat (via WeChat Work).** Chinese enterprise.

### Skip

These do not fit the orchestration use case and should not be added as
dotbot channels:

- **iMessage.** Apple Messages for Business approval is too gated for
  general use.
- **Signal.** Limited bot tooling; per-installation phone number model
  does not scale to multi-recipient fan-out.
- **IRC, Nostr, Twitch, Tlon.** Wrong category (no rich interactive
  controls, or live-stream / decentralised social).
- **Voice Call.** Telephony, not chat. Useful only as an escalation
  channel; out of scope for the orchestrate-humans pattern.
- **Synology Chat, Nextcloud Talk.** Too niche.
- **QQ Bot, Yuanbao, Zalo, Zalo Personal.** Narrow geographic reach or
  consumer-only.
- **WebChat.** OpenClaw's own bundled UI, not an external destination;
  dotbot already plans its own web form in Phase 13.
