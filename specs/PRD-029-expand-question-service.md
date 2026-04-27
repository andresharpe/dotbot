# PRD-029: Expand QuestionService — Artifact Approvals and New Question Types

| Field | Value |
|-------|-------|
| **Issue** | [#29](https://github.com/andresharpe/dotbot/issues/29) |
| **Author** | Dmitry Kuleshov |
| **Date** | 2026-04-19 |
| **Status** | FINAL |
| **Dependencies** | None (builds on existing QuestionService infrastructure) |

---

## 1. Problem Statement

The QuestionService currently supports only **single-choice questions** (with optional free text) delivered to a **flat recipient list** via a **single channel per request**. This limits dotbot's ability to:

- Request **stakeholder sign-off** on generated artifacts (architecture docs, PRDs, diagrams)
- Gather **structured input** beyond option selection (free-text answers, priority rankings, document reviews)
- **Attach generated artifacts** (rendered markdown, diagrams) to question notifications for review on the server
- Give recipients enough **context in-channel** to triage without opening the web form

These gaps block the vision of dotbot as an autonomous agent that collaborates with human stakeholders through structured, auditable decision workflows.

### Design Principle: Rich Notification + Link-to-Server

Channel messages and the web form split responsibility deliberately:

- **Channels (Teams, Email, Slack, Jira) are the *context surface*.** Every notification carries a rich human-in-the-loop summary: question title + type, a 1–3 line deliverable summary, the list of attachments to review, any external review links, and — for batched questions — the other questions in the same batch. A reviewer can judge urgency and scope from their inbox/chat, without clicking through.
- **The Mothership web form is the *interaction surface*.** All actual submission — button clicks, comments, drag-and-drop ranking, document-review confirmation — happens here via a magic link. Keeping submission in one place means new question types don't multiply per-channel rendering work.

Channels stay read-only. Interaction lives on the web form.

---

## 2. Goals

1. **Artifact approval workflow** — stakeholders can approve/reject generated documents with comments, via any delivery channel (notification → Mothership web form). Outpost Decisions tab push-back is P2 scope (see §7).
2. **New question types** — approval (yes/no/abstain + comments), document review, free-text input, priority ranking
3. **Attachment support** — generated artifacts (markdown→PDF, diagrams, code diffs) referenced inline with questions across all channels
4. **Rich in-channel summaries** — every notification contains deliverable summary, attachment list, review links, and the batch's other questions (when the instance carries multiple), so a reviewer can triage in place

### Non-Goals

- **Phase 13 (Multi-Channel Q&A) alignment** — out of scope. This PRD is independent; Phase 13 can adopt or extend these models when/if it is started.
- **Role-based question routing** — targeting by role/domain requires the team registry (Phase 14, [#98](https://github.com/andresharpe/dotbot/issues/98)), not yet implemented. Deferred to Phase 14.
- Full questionnaire/batched-question API (`POST /api/questionnaires`)
- New delivery channels beyond the existing four (Teams, Email, Jira, Slack)
- Per-recipient multi-channel fallback (if Teams fails, try email)
- **Governance enforcement** — no quorum rules, no auto-approve policies. Approvals use **first-response-wins** semantics (later responses recorded with agreement/disagreement flags on the instance blob). Quorum belongs to a later governance phase alongside role support.
- **In-channel interactive submission** — no Adaptive Card form posts, no Slack modals. Submission stays on the web form.
- **Eager attachment download on the outpost** — the poller records attachment references only. If a tool needs the bytes, it fetches via `GET /api/attachments/{storageRef}` on demand.
- **Attachment cleanup / orphan sweep** — not implemented in v1. Orphans from failed uploads, superseded templates, or deleted questions remain in storage; manual cleanup if ever needed. On known client-side upload failures the outpost calls `DELETE /api/attachments/{storageRef}` for already-uploaded files in the same publish, so successful-partial-then-failed publishes don't leak. Crash-mid-publish is accepted debt.

---

## 3. Current State

### 3.1 What Exists

| Component | State | Details |
|-----------|-------|---------|
| `QuestionTemplate` | Single type | `Type = "singleChoice"`, options with pros/cons, `ResponseSettings` for multi-select and free text |
| `QuestionInstance` | Flat recipients | `SentTo: List<InstanceRecipient>` with email/AadObjectId/SlackUserId, single channel |
| `ResponseRecordV2` | Option + text | `SelectedOptionId`, `FreeText`, `Attachments` (response-side only) |
| `CreateInstanceRequest` | Single channel | One `Channel` field, flat `Recipients` |
| Delivery providers | 4 channels | Teams (Adaptive Cards), Email (HTML), Jira (wiki tables), Slack (Block Kit) |
| `DeliveryOrchestrator` | Basic routing | Channel validation, business hours, magic links, reminders/escalation |
| Outpost MCP | Batch questions | `task-mark-needs-input` groups questions; `task-answer-question` handles batch responses; `NotificationPoller.psm1` tracks batch state |

### 3.2 What's Missing

- No `Type` enum — the `"singleChoice"` string is the only known value
- No attachment support on `QuestionTemplate` (only on `ResponseRecordV2`)
- No approval-specific response model (approve/reject/abstain + comments)
- No dual-surface approval sync between Outpost and Mothership
- No review link model to reference external artifacts for in-context review
- **No shared notification-summary model** — each provider hand-rolls its own message, so adding a field (e.g. attachment list) today means editing four files with drift between them

---

## 4. Proposed Design

### 4.1 Question Type System

Introduce a string-constant taxonomy for `Type` on `QuestionTemplate` (validated at the API boundary — see the `QuestionTypes` class below):

| Type | Behavior | Options | Response Model |
|------|----------|---------|----------------|
| `singleChoice` | Select one option from a list (current behavior) | Required, 2+ options | `SelectedOptionId` + optional `FreeText` |
| `approval` | Approve/reject/abstain with mandatory comment on reject | Fixed: Approve, Reject, Abstain | `ApprovalDecision` (`approved` \| `rejected` \| `abstained`) + `Comment` (required on reject) |
| `documentReview` | Review attached artifact(s) and provide feedback | Fixed: Approve, Request Changes, Comment Only | `ApprovalDecision` (`approved` \| `changes_requested` \| `comment_only`) + `Comment` + `ReviewedAttachmentIds` |
| `freeText` | Open-ended text response | None (no options) | `FreeText` (required) |
| `priorityRanking` | Rank items by ordinal priority (no weights) | Required, 2+ items to rank | `RankedItems[]` (ordered list of option IDs) |

**Server model changes:**

```csharp
// QuestionTemplate.cs — extend
public class QuestionTemplate
{
    // ... existing fields ...
    public string Type { get; set; } = "singleChoice";  // validated against QuestionTypes.AllowedTypes
    public List<Attachment>? Attachments { get; set; }   // NEW
    public List<ReviewLink>? ReviewLinks { get; set; }   // NEW
    public string? DeliverableSummary { get; set; }      // NEW — 1-3 line summary for notifications
}
```

The `Options` field remains required for `singleChoice` and `priorityRanking`, is auto-generated (Approve/Reject/Abstain) for `approval` and `documentReview`, and empty for `freeText`.

A static `QuestionTypes` class (`Models/QuestionTypes.cs`) holds the five string constants (`QuestionTypes.SingleChoice`, `QuestionTypes.Approval`, etc.) plus `AllowedTypes` for validation. The server validates `QuestionTemplate.Type` against `AllowedTypes` at `POST /api/templates` and rejects typos with `400 Bad Request`.

`DeliverableSummary` is the author-supplied 1-3 sentence explanation of *what needs review*. It is rendered prominently in every channel notification. **Required** for `approval` and `documentReview` templates (validated at `POST /api/templates`; rejected with `400 Bad Request` if missing or blank); **optional** for `singleChoice`, `freeText`, and `priorityRanking` where the title + options carry enough context on their own.

`priorityRanking` uses **ordinal ranks only** (1 = highest priority, 2 = next, …). No weighted scores in this release — a future enhancement could add an optional `Weight: double?` on `RankedItem` non-breakingly.

### 4.2 Attachment & Review Link Models

```csharp
// Models/Attachment.cs — NEW
public class Attachment
{
    public required string Name { get; set; }          // "architecture-v2.pdf"
    public required string ContentType { get; set; }   // "application/pdf"
    public required string StorageRef { get; set; }    // blob reference from upload
    public long? SizeBytes { get; set; }
    public string? Description { get; set; }
}

// Models/ReviewLink.cs — NEW
public class ReviewLink
{
    public required string Title { get; set; }         // "PR #42 — Schema changes"
    public required string Url { get; set; }           // external URL
    public string? Type { get; set; }                  // "pull-request"|"document"|"design"|"other"
    public string? Description { get; set; }
    public bool RequiresReview { get; set; }           // must confirm reviewed before responding
}
```

**Storage abstraction.** A single `IAttachmentStorage` interface with two implementations from day one:

- **Azure Blob** — cloud deployments
- **Local filesystem** — self-hosted deployments

Selected via config. Interface surface: `UploadAsync`, `DownloadAsync`, `DeleteAsync`. `DownloadAsync` returns a stream; the Mothership proxies file content through `GET /api/attachments/{storageRef}`. Both backends present the same contract — clients never talk to Azure Blob or the filesystem directly. If bandwidth later becomes a concern for the Azure Blob case, `GetSignedUrlAsync` can be added non-breakingly and direct-to-storage downloads enabled per-backend.

**Endpoints:**

```
POST /api/attachments
Content-Type: multipart/form-data
→ { attachmentId, storageRef, name, contentType, sizeBytes }

GET  /api/attachments/{storageRef}?token={jwt}
→ binary stream. Authorized by the same magic-link JWT that gates /respond.
→ Middleware checks: JWT signature, JTI not consumed, storageRef owned by JWT's instanceId.
→ Called by the web form only — channels do not carry download links.
```

**`storageRef` format and validation.** `storageRef` is **server-issued only** — clients never construct one. Format: `{instanceId-guid}/{sanitized-filename}` where sanitized-filename matches `[A-Za-z0-9._-]+`. `GET /api/attachments/{storageRef}` validates the pattern on entry and rejects anything containing `..`, `/..`, `\`, null bytes, or absolute paths with `400 Bad Request`.

**Size limits** (both configurable):

- `BlobStorage:MaxAttachmentSizeMb` — per-file cap, default **15 MB** (aligned with existing `Respond.cshtml`)
- `BlobStorage:MaxTotalAttachmentsPerQuestionMb` — per-question total cap, default **50 MB**

Channels show attachment **names and sizes only** as metadata — so the recipient knows what the review will contain. **No download URLs in the channel message.** All downloads happen on the Mothership web form (reached via the magic link), authorized by the same magic-link JWT. `GET /api/attachments/{storageRef}?token={jwt}` requires the JWT's `instanceId` to own the requested `storageRef`.

**Attachment download authorization.** `GET /api/attachments/{storageRef}` is covered by the same `MagicLinkAuthMiddleware` that gates `/respond`. The web form renders each download link as `/api/attachments/{storageRef}?token={jwt}`, reusing the magic-link JWT already present in the `/respond` URL. The middleware validates the JWT, verifies the JWT's `instanceId` owns the requested `storageRef`, and streams the file. No separate cookie or session mechanism is introduced. The existing **device cookie** (30-day lifetime, set at form POST time for recipient-email recognition across magic-link reissues) is unchanged and unrelated to attachment downloads.

### 4.3 Response Model Extension

Extend `ResponseRecordV2` to capture type-specific response data:

```csharp
public class ResponseRecordV2
{
    // ... existing fields (SelectedOptionId, FreeText, etc.) ...

    // NEW — approval/review responses
    // Values scoped by QuestionTemplate.Type:
    //   approval:       "approved" | "rejected" | "abstained"
    //   documentReview: "approved" | "changes_requested" | "comment_only"
    public string? ApprovalDecision { get; set; }
    public string? Comment { get; set; }                // required on reject
    public List<Guid>? ReviewedAttachmentIds { get; set; }
    public List<RankedItem>? RankedItems { get; set; }  // for priorityRanking
}

public class RankedItem
{
    public required Guid OptionId { get; set; }
    public required int Rank { get; set; }              // 1 = highest priority (ordinal only)
}
```

Backwards-compatible: existing `singleChoice` responses continue using `SelectedOptionId` + `FreeText`.

### 4.4 Dual-Surface Approval Flow

Per the whitepaper (section 6.2.1), approvals work on both the Outpost Decisions tab and via Mothership channels. For `approval` and `documentReview` question types:

1. Outpost publishes template with `Type = "approval"` + attachments
2. Mothership creates instance → delivers notifications to channels AND marks as pending in Decisions API
3. Respondent approves via **either** surface:
   - **Channel notification → Mothership web form:** reads full context from the rich notification, clicks magic link → opens question page → submits response
   - **Outpost:** approves in the Decisions tab locally
4. **First response (by timestamp) is authoritative.** No quorum, no override — this is the governance posture for v1. Applies in the P0 single-surface flow (only the web form exists) and in the P2 dual-surface flow.
5. Mothership syncs the decision back to the originating outpost
6. **(P2 only)** With dual-surface enabled, a second response may arrive after the task has transitioned. The task state does not change. The second response is stored on the instance blob with its own timestamp and **flagged in the dashboard as agreement (same decision) or disagreement (different decision) for human review** — the flag is derived at read time by comparing to the first response's `ApprovalDecision`. Without dual-surface (P0 scope), only one response is possible per batch question.

**No new API endpoints needed** — the existing `POST /api/responses` and `ResponseRecordV2` accommodate this with the new `ApprovalDecision` field. The Outpost's Decisions tab needs a UI update to render approval-type questions (out of scope for this PRD — tracked separately).

### 4.5 Channel Delivery Model: Rich Notification + Link

**All channels render a shared `NotificationSummary`** — a single in-memory shape built **once per instance** by `DeliveryOrchestrator` (including the per-question answered-state lookup against `ResponseStorageService`). Only the magic-link URL (`RespondUrl`) is personalized per recipient before the summary is handed to the provider. Providers own only the *rendering* (Adaptive Card / HTML / Block Kit / wiki-format comment); they no longer compose message bodies from raw template fields.

```csharp
// Services/Delivery/NotificationSummary.cs — NEW
public class NotificationSummary
{
    public required string QuestionTitle { get; set; }       // "Approve architecture v2"
    public required string QuestionType { get; set; }        // used for badge
    public required string ProjectName { get; set; }

    public string? DeliverableSummary { get; set; }          // 1-3 line "what needs review"
    public string? Context { get; set; }                     // longer context from template

    // Batch questions — all questions in the current instance's batch, each with its state.
    // The outpost groups questions when it calls task-mark-needs-input;
    // single-question instance → one entry. No cross-instance lookup.
    public List<BatchQuestionRef> BatchQuestions { get; set; } = new();

    public List<AttachmentRef> Attachments { get; set; } = new();
    public List<ReviewLinkRef> ReviewLinks { get; set; } = new();

    public required string RespondUrl { get; set; }          // magic link to web form
    public DateTime? DueBy { get; set; }
    public bool IsReminder { get; set; }
}

public class BatchQuestionRef
{
    public required Guid QuestionId { get; set; }
    public required string Title { get; set; }
    public required string Type { get; set; }

    // State — sourced from existing ResponseRecordV2 for (instanceId, questionId).
    // NotificationSummaryBuilder queries ResponseStorageService to populate these.
    public bool IsAnswered { get; set; }                     // true if a response exists
    public string? AnsweredSummary { get; set; }             // e.g. "Approved", "Rank: 1,3,2"
}

public class AttachmentRef
{
    public required string Name { get; set; }
    public required string ContentType { get; set; }
    public long? SizeBytes { get; set; }
    // No DownloadUrl — channels do not link to files. Downloads happen on the web form
    // after the magic link is followed. See §4.2.
}

public class ReviewLinkRef
{
    public required string Title { get; set; }
    public required string Url { get; set; }
    public string? Type { get; set; }
}
```

**Every channel displays, in its own native format:**

1. **Header** — question title + type badge + project name + reminder marker
2. **Deliverable summary** (prominent)
3. **Context** — optional longer block
4. **Batch-question list** — all questions from the current instance's batch, bulleted with title + type (single-question instance = single entry). Already-answered questions are rendered with a ✓ marker and their `AnsweredSummary`; unanswered questions point to the Respond Now link. The notification is **one link per instance** — the web form opens showing every batch question with its current state.
5. **Attachments** — name + size only (download happens on the web form after Respond Now)
6. **Review links** — title + URL (+ "requires review" marker if set; external URLs are safe to link directly)
7. **Respond Now** — the only action that leaves the channel; points at the web form

**Per-channel rendering notes:**

| Channel | Format | Rendering notes |
|---------|--------|-----------------|
| Email | HTML (existing CRT theme) | Full sections, attachment list as a plain table (name + size, no links), batch-question bullets, single CTA button → Respond Now |
| Teams | Adaptive Card | TextBlocks for header/summary/context, FactSet for batch questions, attachment list as TextBlocks (name + size), single Action.OpenUrl → Respond Now |
| Slack | Block Kit | `section` blocks for summary + batch-question list; attachment list as mrkdwn bullets (name + size); `actions` block with a single Respond Now button |
| Jira | Issue comment | Wiki-format: `h3.` header, paragraph summary, `*` bulleted lists, magic link URL inline as the only clickable element |

**The Mothership web form (`Respond.cshtml`) remains the single rich interaction surface.** It handles all question types with full interactivity. **For batched instances, each question is rendered with its current state: answered questions appear as read-only summaries; unanswered questions render the input form for that type.** The form reflects the live state of the instance — reloading after submitting one question shows that question as done and the rest still pending.

| Type | Web Form Rendering |
|------|--------------------|
| `singleChoice` | Radio buttons + optional free text (current behavior) |
| `approval` | Approve/Reject/Abstain buttons + comment textarea (required on reject) |
| `documentReview` | Attachment list with a confirmation checkbox per item (recorded in `ReviewedAttachmentIds`) + decision buttons (Approve / Request Changes / Comment Only) + feedback textarea |
| `freeText` | Multiline textarea (required) |
| `priorityRanking` | Drag-and-drop sortable list |

**Benefits of this split (rich channel / interactive web form):**
- **Zero per-channel work** for new question types — add the type to the web form only; every channel already displays the summary
- **Consistent UX** — respondents always see the same form regardless of channel
- **Simpler provider code** — each provider renders one shape; no conditional logic per question type
- **Future-proof** — adding a new channel (Discord, WhatsApp, web) means implementing one renderer

### 4.6 Outpost-Side Changes

**MCP tool: `task-mark-needs-input`** — extend metadata/script:

```yaml
# New parameters
- name: type
  type: string
  enum: [singleChoice, approval, documentReview, freeText, priorityRanking]
  description: Question type (default: singleChoice)

- name: deliverable_summary
  type: string
  description: 1-3 line summary of what needs review (shown in channel notifications)

- name: attachments
  type: array
  description: File paths to attach (uploaded to Mothership)
  items:
    type: object
    properties:
      path: { type: string }
      description: { type: string }

- name: review_links
  type: array
  description: External URLs for reviewer context
  items:
    type: object
    properties:
      title: { type: string }
      url: { type: string }
      type: { type: string, enum: [pull-request, document, design, other] }
```

**`NotificationClient.psm1`** — extend to:
1. Upload attachments via `POST /api/attachments` before creating template
2. Include `type`, `deliverable_summary`, `attachments`, `reviewLinks` on template
3. Handle type-specific response parsing on poll (metadata only — no file download)

**`task-answer-question`** — extend to handle approval/review responses:
- Accept `decision` parameter — valid values vary by question type (see §4.1 table): `approval` accepts `approved` / `rejected` / `abstained`; `documentReview` accepts `approved` / `changes_requested` / `comment_only`
- Accept `comment` parameter (required when `decision = rejected` on an `approval` question)
- Accept `ranked_items` for priority ranking

---

## 5. Communication Flow

The Outpost-Mothership integration uses **pull-based polling** — no persistent connection, no webhooks, no push. The Outpost polls every 30 seconds for responses.

### 5.1 Current Integration Architecture

```
OUTPOST (PowerShell)                    MOTHERSHIP (.NET Server)
─────────────────────                   ─────────────────────────

NotificationClient.psm1                Program.cs (API endpoints)
MothershipClient.psm1                   DeliveryOrchestrator
NotificationPoller.psm1                 ResponseStorageService
                                        MagicLinkService
                                        NotificationSummaryBuilder (NEW)
                                        IAttachmentStorage (NEW, 2 impls)

  ──── Push (Outpost → Mothership) ────
  POST /api/templates                   Store QuestionTemplate blob
  POST /api/instances                   Create QuestionInstance + deliver
  POST /api/attachments                 Upload file to blob store (NEW)
  POST /api/responses                   Push local approval (NEW, P2)

  ──── Pull (Outpost ← Mothership) ────
  GET  /api/instances/{p}/{q}/{i}/responses   Return ResponseRecordV2[]
  GET  /api/attachments/{storageRef}          Stream file (requires ?token={jwt}; middleware checks instanceId owns storageRef)
  GET  /api/health                            Server availability check
```

### 5.2 Question Publication (Outpost → Mothership)

```
 OUTPOST                                           MOTHERSHIP
 ──────                                            ──────────
 Claude (analysis phase)
   │
   │ calls task-mark-needs-input
   │   type: "approval"
   │   deliverable_summary: "Architecture v2 introduces ..."
   │   attachments: [architecture-v2.pdf]
   │
   ▼
 Invoke-TaskMarkNeedsInput
   │
   ├─1─ Upload attachments ──────────────────────► POST /api/attachments
   │    (multipart/form-data)                      → IAttachmentStorage.UploadAsync()
   │                                               ◄── { attachmentId, storageRef }
   │
   ├─2─ Publish template ───────────────────────► POST /api/templates
   │    { questionId, type, title,                  → blob: /projects/{p}/questions/{q}/v{v}.json
   │      deliverableSummary, options,
   │      attachments, reviewLinks, project }
   │
   └─3─ Create instance ────────────────────────► POST /api/instances
        { instanceId, questionId,                   │
          channel, recipients }                     ▼
                                                  DeliveryOrchestrator.DeliverToAllAsync()
                                                    │
                                                    ├── NotificationSummaryBuilder.Build(instance)
                                                    │   → merges template + instance batch +
                                                    │     per-question answered state
                                                    │     (from ResponseStorageService)
                                                    │
                                                    ├── For each recipient:
                                                    │   ├── MagicLinkService.GenerateMagicLinkAsync()
                                                    │   │   → JWT with {email, instanceId, projectId}
                                                    │   │
                                                    │   ├── Personalize(summary, magicLink)
                                                    │   │   → fills RespondUrl for this recipient
                                                    │   │
                                                    │   └── Provider.DeliverAsync(personalizedSummary)
                                                    │       → Teams:  Adaptive Card
                                                    │       → Email:  HTML
                                                    │       → Slack:  Block Kit
                                                    │       → Jira:   wiki comment
                                                    │
                                                    └── Store instance blob with SentTo statuses
                                                        → blob: /projects/{p}/instances/{i}.json

 Task file updated:
   status: "needs-input"
   notification: { question_id, instance_id, channel, sent_at }
```

### 5.3 Response Submission (User → Mothership)

```
 USER (any channel)                                MOTHERSHIP
 ──────────────────                                ──────────

 Receives rich notification
 (sees title, summary, attachments,
  batch's other questions, all in-channel)
   │
   │ clicks magic link to submit
   ▼
 GET /respond?token={jwt} ─────────────────────► MagicLinkAuthMiddleware
                                                    │ validate JWT, check JTI expiry
                                                    │   (expired → 410 Gone)
                                                    │ extract email, instanceId
                                                    ▼
                                                  Respond.cshtml.OnGetAsync()
                                                    │ load QuestionTemplate + Instance
                                                    │ query existing ResponseRecordV2 blobs
                                                    │   → per-question state (answered/pending)
                                                    │ render each batch question:
                                                    │   answered   → read-only summary
                                                    │   pending    → type-specific form:
                                                    │     singleChoice → radio buttons
                                                    │     approval → approve/reject/abstain + comment
                                                    │     documentReview → per-attachment checklist + decision + feedback
                                                    │     freeText → textarea
                                                    │     priorityRanking → drag-and-drop list
                                                    ▼
 User submits form ────────────────────────────► Respond.cshtml.OnPostAsync()
   { questionId, selectedKey, freeText,             │
     approvalDecision, comment,                     ├── Validate response vs template
     rankedItems }                                  ├── Save ResponseRecordV2 blob for (instanceId, questionId)
                                                    ├── Check batch completion:
                                                    │   → all batch questions have responses?
                                                    │     yes → mark magic link JTI consumed
                                                    │     no  → JTI stays valid; reviewer can return
                                                    └── Set device cookie (30 days); redirect back
                                                        to form (now showing this question as done)

 Magic-link JTI hard expiry:
   SentAt + Template.DeliveryDefaults.EscalateAfterDays
   (default 30 days if EscalateAfterDays is null)
   → after expiry, /respond?token=X returns 410 Gone;
     abandoned partial batches naturally clean themselves up.
```

### 5.4 Response Polling (Outpost ← Mothership)

```
 OUTPOST                                           MOTHERSHIP
 ──────                                            ──────────

 NotificationPoller.psm1
   (background runspace, every 30s)
   │
   │ For each task with notification metadata:
   │
   ├── GET /api/instances/{p}/{q}/{i}/responses ──► ResponseStorageService
   │                                                  list blobs matching pattern
   │   ◄── ResponseRecordV2[] (sorted by time) ◄──   return all responses
   │
   │ If response found:
   │   │
   │   │   (attachment references recorded in task JSON;
   │   │    bytes fetched on demand, not during poll)
   │   │
   │   ├── Single question:      → move task needs-input → analysing
   │   ├── Batch questions:      → mark answered; move only when ALL done
   │   └── Split proposal:       → delegate to task-approve-split or mark rejected
   │
   ▼
 Task JSON updated:
   questions_resolved: [{
     id, question, answer, answer_type,
     approval_decision,          ← NEW for approval types
     comment,                    ← NEW
     attachment_refs,            ← NEW (refs only, not bytes)
     asked_at, answered_at,
     answered_via: "notification"
   }]
```

### 5.5 Dual-Surface Approval Sync

Approvals can be submitted from two surfaces: the **Mothership web form** (via channel notification) and the **Outpost Decisions tab** (locally). The sync uses the existing pull-based architecture — no new push mechanism needed.

```
 OUTPOST Decisions Tab                  MOTHERSHIP Web Form
 ─────────────────────                  ────────────────────
       │                                       │
       │  User approves locally                │  User approves via magic link
       ▼                                       ▼
 Save to local task JSON               Save ResponseRecordV2 blob
 approval_decision: "approved"         approvalDecision: "approved"
 answered_via: "outpost"               → available on next poll
       │                                       │
       ▼                                       ▼
 POST /api/responses ──────────►  Store as ResponseRecordV2
 (push local decision to server)

                                   ┌────────────────────────────────────┐
                                   │ RESOLUTION                         │
                                   │  → First by timestamp wins         │
                                   │  → Later responses recorded with   │
                                   │    agreement/disagreement flag     │
                                   │    (derived at read time)          │
                                   │  → Never overrides the first       │
                                   └────────────────────────────────────┘
```

**New Outpost-side requirement:** The Decisions tab needs a "push-back" path — when a user approves locally, `NotificationClient.psm1` must call `POST /api/responses` to write the decision to the Mothership so it's visible fleet-wide. This is a new capability (today the Outpost only pushes questions, never responses).

**Idempotency.** The outpost generates a `ResponseId` (Guid) once per local approval. It includes this ID in the `POST /api/responses` body. The server treats the endpoint as an upsert: if a blob already exists for that `ResponseId`, it returns `200 OK` with the existing record; otherwise it stores a new one. This means transient-network retries never create duplicates. Different surfaces (web form vs outpost) generate different `ResponseId`s, so both are stored and first-wins applies on decision timestamp.

### 5.6 Reminder & Escalation (Server-Side Background)

Mostly unchanged from current behavior. `ReminderEscalationService` scans active instances and triggers `DeliveryOrchestrator.DeliverReminderAsync()` at `ReminderAfterHours`; status transitions "sent" → "reminded" → "escalated" at `EscalateAfterDays`.

**Null-field handling:** If `ReminderAfterHours` is null, no reminder fires. If `EscalateAfterDays` is null, no escalation transition happens (status stays "reminded"). This is distinct from the JTI-expiry default in §5.3, which *does* fall back to 30 days when `EscalateAfterDays` is null — because the JTI must have a hard lifetime even when escalation is disabled.

**New rule for batched instances:** before delivering a reminder, the service queries `ResponseStorageService` for existing responses on the instance. If every batch question already has a response, the reminder is **suppressed** (the instance is effectively complete and the outpost poller will reconcile on its next tick). If some questions are answered and others are not, the reminder is delivered; the `NotificationSummary` built for it naturally reflects per-question state via `IsAnswered` and `AnsweredSummary`, so the recipient sees a mix of ✓-marked (done) and pending items.

---

## 6. Files to Create/Modify

### Server-side (Mothership)

| Action | Path | Change |
|--------|------|--------|
| Create | `Models/Attachment.cs` | Attachment record with name, content type, storage ref |
| Create | `Models/ReviewLink.cs` | Review link with title, URL, type, requires-review flag |
| Create | `Models/RankedItem.cs` | Priority ranking response item (ordinal Rank) |
| Create | `Models/QuestionTypes.cs` | String constants for question types + `AllowedTypes` validation array |
| Create | `Services/IAttachmentStorage.cs` | Storage abstraction: Upload / Download (stream) / Delete |
| Create | `Services/AzureBlobAttachmentStorage.cs` | Azure Blob implementation |
| Create | `Services/LocalFileAttachmentStorage.cs` | Local filesystem implementation |
| Create | `Services/Delivery/NotificationSummary.cs` | Shared summary DTO (see §4.5) |
| Create | `Services/Delivery/NotificationSummaryBuilder.cs` | Builds summary from template + instance batch + per-question answered state (queries `ResponseStorageService`) |
| Modify | `Models/QuestionTemplate.cs` | Add `Attachments`, `ReviewLinks`, `DeliverableSummary` |
| Modify | `Models/ResponseRecordV2.cs` | Add `ApprovalDecision`, `Comment`, `ReviewedAttachmentIds`, `RankedItems` |
| Modify | `Services/Delivery/IQuestionDeliveryProvider.cs` | `DeliveryContext` carries `NotificationSummary` |
| Modify | `Services/Delivery/DeliveryOrchestrator.cs` | Build summary **once per instance** via `NotificationSummaryBuilder`; personalize `RespondUrl` per recipient; hand to provider |
| Modify | `Services/Delivery/TeamsDeliveryProvider.cs` | Adaptive Card renders full `NotificationSummary` |
| Modify | `Services/Delivery/EmailDeliveryProvider.cs` | HTML email renders full `NotificationSummary` |
| Modify | `Services/Delivery/SlackDeliveryProvider.cs` | Block Kit renders full `NotificationSummary` |
| Modify | `Services/Delivery/JiraDeliveryProvider.cs` | Wiki comment renders full `NotificationSummary` |
| Modify | `Pages/Respond.cshtml` | Full question-type handling: approval form, ranking drag-and-drop, document review, free text |
| Create | API endpoint: `POST /api/attachments` | Multipart upload → `IAttachmentStorage` |
| Create | API endpoint: `GET /api/attachments/{storageRef}` | Stream blob content; middleware validates `?token={jwt}` and verifies JWT's `instanceId` owns the `storageRef` |

### Outpost-side (Client)

| Action | Path | Change |
|--------|------|--------|
| Modify | `systems/mcp/tools/task-mark-needs-input/metadata.yaml` | Add `type`, `deliverable_summary`, `attachments`, `review_links` params |
| Modify | `systems/mcp/tools/task-mark-needs-input/script.ps1` | Upload attachments, include new fields on template |
| Modify | `systems/mcp/tools/task-answer-question/metadata.yaml` | Add `decision`, `comment`, `ranked_items` params |
| Modify | `systems/mcp/tools/task-answer-question/script.ps1` | Handle type-specific response fields |
| Modify | `systems/mcp/modules/NotificationClient.psm1` or `MothershipClient.psm1` | Attachment upload, type-specific response parsing (refs only), push-back local approvals |
| Modify | `systems/ui/modules/NotificationPoller.psm1` | Handle approval/review response types, update Decisions tab state on poll |

---

## 7. Acceptance Criteria

### P0 — Must Have

- [ ] `QuestionTemplate.Type` supports values: `singleChoice`, `approval`, `documentReview`, `freeText`, `priorityRanking`
- [ ] `QuestionTemplate` accepts optional `Attachments` and `ReviewLinks`; `DeliverableSummary` is **required** for `approval` + `documentReview` (validated at `POST /api/templates`), optional for other types (see §4.1)
- [ ] `NotificationSummary` DTO + `NotificationSummaryBuilder` exist and are used by all four providers
- [ ] All 4 channels (Teams, Email, Slack, Jira) render notifications containing: question title + type badge, deliverable summary, attachment list, review-link list, batch-question list (every question in the current instance's batch, each with its `IsAnswered` state), magic link to web form
- [ ] Mothership web form (`Respond.cshtml`) supports all question types with full interactivity
- [ ] `IAttachmentStorage` abstraction with **both** `AzureBlobAttachmentStorage` and `LocalFileAttachmentStorage` implementations; backend selectable via config
- [ ] `POST /api/attachments` + `GET /api/attachments/{storageRef}` functional; per-file limit 15 MB, per-question total limit 50 MB (both configurable)
- [ ] `ResponseRecordV2` captures `ApprovalDecision`, `Comment` for approval/review responses
- [ ] `task-mark-needs-input` MCP tool accepts `type`, `deliverable_summary`, `attachments`, `review_links`
- [ ] `task-answer-question` MCP tool accepts `decision`, `comment` for approval responses
- [ ] Outpost poller records attachment references only (no eager download)
- [ ] Approval uses first-response-wins semantics (no quorum)
- [ ] Reject on `approval` type requires a non-empty `Comment` — validated on server + web form
- [ ] Batched instance web form: answered questions render as read-only summaries; unanswered render as input forms; magic-link JTI remains valid until every question in the batch has a response
- [ ] Existing `singleChoice` behavior fully backwards-compatible

### P1 — Should Have

- [ ] `documentReview` type with per-attachment confirmation checklist and decision buttons (Approve / Request Changes / Comment Only) in web form
- [ ] `priorityRanking` type with drag-and-drop ranking in web form (ordinal only)
- [ ] Batch-question list in notifications enumerates every question in the current instance's batch (relies on existing batching — no cross-instance queries)
- [ ] Channel notifications (including reminders) mark already-answered batch questions with a ✓ and `AnsweredSummary`; unanswered questions point at the instance-scoped Respond Now link

### P2 — Nice to Have

- [ ] Dual-surface approval sync: Outpost Decisions tab push-back via `POST /api/responses` (see §5.5)
- [ ] Poller reads approval responses and updates Decisions tab state
- [ ] Dual-surface conflict handling: first-by-timestamp wins, later responses recorded on instance blob with agreement/disagreement flag derived at read time
- [ ] `ReviewLink.RequiresReview` enforcement (must confirm reviewed before submitting response)
- [ ] Attachment inline preview in web form (PDF viewer, image preview, markdown render)

### Polish (deferred — decide during implementation, not blocking plan)

- [ ] **Content-type filter on upload** (`POST /api/attachments`) — minimal blacklist of executable extensions (`.exe`, `.msi`, `.dll`, `.bat`, `.sh`, `.ps1`, `.cmd`, `.scr`, `.vbs`). Attachments in practice come from Claude-generated output, so risk is low.
- [ ] **`NotificationSummary.DueBy` derivation** — default rule `Instance.SentAt + Template.DeliveryDefaults.EscalateAfterDays` (null if `EscalateAfterDays` not set); rendered as "Due by: {date}" in header.
- [ ] **Reminder rendering convention** — `IsReminder=true` surfaces in each channel: email subject prefixed `"Reminder: "`; Teams/Slack/Jira show `⏰ REMINDER` marker + *"Originally sent: {timestamp}"* line in header.
- [ ] **Consolidated configuration appendix (§10)** — one-page reference of all config keys and defaults (`BlobStorage:*`, any `NotificationSummary:*`).

---

## 8. Migration & Backwards Compatibility

- **No breaking changes.** All new fields are optional/nullable on existing models.
- Existing `singleChoice` templates continue to work unchanged; `NotificationSummary` for them carries empty attachment/review-link lists and the existing title/context as the deliverable summary fallback.
- `CreateInstanceRequest` continues using the existing flat `Recipients` list. Role-based targeting will be added when Phase 14 (team registry) is implemented.
- `ResponseRecordV2` without `ApprovalDecision` is interpreted as a legacy single-choice response.
- `QuestionTemplate.Type` defaults to `"singleChoice"` for existing templates.

---

## 9. Related Issues & Documents

- [#29](https://github.com/andresharpe/dotbot/issues/29) — This issue
- [#30](https://github.com/andresharpe/dotbot/issues/30) — Jira approval channel
- [#98](https://github.com/andresharpe/dotbot/issues/98) — Team registry (Phase 14) — role-based routing deferred to this issue
- [Phase 14: Project Team & Roles](../docs/roadmap/DOTBOT-V4-phase-14-project-team-roles.md)
- [UI & Domain Model Whitepaper v2](../docs/whitepapers/UI-AND-DOMAIN-MODEL-WHITEPAPER-v2.md) — section 6.2.1 (dual-surface approval)
