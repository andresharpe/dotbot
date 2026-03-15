# Phase 13: Multi-Channel Q&A with Attachments & Questionnaires

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Current state

The Mothership currently supports three delivery channels: **Teams** (Adaptive Cards via Bot Framework), **Email** (Azure Communication Services), and **Jira** (issue comments). Questions are single-choice with optional free text, sent to a flat `recipients` list. There's no support for attachments, links for review, batched questions, or channel-agnostic delivery configuration.

**Current architecture:**
- `IQuestionDeliveryProvider` interface with `DeliverAsync(DeliveryContext, CancellationToken)`
- `DeliveryOrchestrator` dispatches to registered providers by channel name
- `QuestionTemplate` — single question with options, context, response settings
- `CreateInstanceRequest` — single channel, flat recipient emails/object IDs
- `NotificationClient.psm1` (outpost) — sends template + instance, polls for responses

## Target: Extensible multi-channel delivery with rich content

### New channels

Add provider implementations for popular chat/collaboration platforms:

| Channel | Provider | Auth mechanism |
|---------|----------|----------------|
| Teams | `TeamsDeliveryProvider` | Bot Framework + Graph API (existing) |
| Email | `EmailDeliveryProvider` | Azure Communication Services (existing) |
| Jira | `JiraDeliveryProvider` | API token (existing) |
| **Slack** | `SlackDeliveryProvider` | **Bot token + Web API (NEW)** |
| **Discord** | `DiscordDeliveryProvider` | **Bot token + REST API (NEW)** |
| **WhatsApp** | `WhatsAppDeliveryProvider` | **Azure Communication Services / Twilio (NEW)** |
| **Web** | `WebDeliveryProvider` | **Mothership web UI only — no external push (NEW)** |

Each provider implements `IQuestionDeliveryProvider`. The `DeliveryOrchestrator` already resolves providers by `ChannelName` — new channels slot in with zero changes to orchestration logic.

**Channel settings evolution:**
```csharp
public class DeliveryChannelSettings
{
    public EmailChannelSettings Email { get; set; } = new();
    public JiraChannelSettings Jira { get; set; } = new();
    public SlackChannelSettings Slack { get; set; } = new();
    public DiscordChannelSettings Discord { get; set; } = new();
    public WhatsAppChannelSettings WhatsApp { get; set; } = new();
}

public class SlackChannelSettings
{
    public bool Enabled { get; set; }
    public string? BotToken { get; set; }
    public string? SigningSecret { get; set; }
    public string? DefaultChannel { get; set; }  // #channel for group delivery
}

public class DiscordChannelSettings
{
    public bool Enabled { get; set; }
    public string? BotToken { get; set; }
    public ulong? GuildId { get; set; }
}

public class WhatsAppChannelSettings
{
    public bool Enabled { get; set; }
    public string? ConnectionString { get; set; }
    public string? FromNumber { get; set; }
}
```

### Multi-channel delivery per recipient

Currently, each `CreateInstanceRequest` specifies a single channel for all recipients. Evolve to support per-recipient channel preferences and multi-channel fallback:

```json
POST /api/instances
{
  "instanceId": "...",
  "projectId": "...",
  "questionId": "...",
  "questionVersion": 1,
  "recipients": {
    "entries": [
      {
        "email": "andre@org.com",
        "channels": ["teams", "email"],
        "fallback_order": true
      },
      {
        "email": "dev@org.com",
        "channels": ["slack"],
        "slack_user_id": "U12345"
      }
    ]
  }
}
```

When `fallback_order: true`, the system tries channels in order — if Teams delivery fails, falls back to Email. When `false` (default), delivers to all specified channels simultaneously.

### Attachments

Extend `QuestionTemplate` and `DeliveryContext` to support file attachments and review links:

```csharp
public class QuestionTemplate
{
    // ... existing fields ...
    public List<Attachment>? Attachments { get; set; }
    public List<ReviewLink>? ReviewLinks { get; set; }
}

public class Attachment
{
    public required string Name { get; set; }        // "architecture-diagram.png"
    public required string ContentType { get; set; } // "image/png"
    public required string StorageRef { get; set; }   // Blob reference or base64
    public long? SizeBytes { get; set; }
    public string? Description { get; set; }
}

public class ReviewLink
{
    public required string Title { get; set; }        // "PR #42 - Database schema changes"
    public required string Url { get; set; }          // "https://github.com/org/repo/pull/42"
    public string? Type { get; set; }                 // "pull-request|document|design|other"
    public string? Description { get; set; }          // "Review the schema changes before approving"
    public bool RequiresReview { get; set; }          // If true, reviewer must confirm they reviewed
}
```

**Attachment storage:** Mothership stores attachments in a configurable blob store (local filesystem for self-hosted, Azure Blob for cloud). Each channel provider renders attachments appropriately:
- **Teams:** Inline images in Adaptive Card, file download links
- **Email:** MIME attachments + inline images
- **Slack:** File uploads via `files.upload` API
- **Web:** Direct download links on response page
- **Jira:** Attached to issue

**Outpost-side:** The MCP tool `task-mark-needs-input` gains optional `attachments` and `review_links` parameters. `NotificationClient.psm1` / `MothershipClient.psm1` uploads attachments before creating the template:

```powershell
# Upload attachment
POST /api/attachments
Content-Type: multipart/form-data
-> { attachment_id, storage_ref }

# Then reference in template
$template.attachments = @(
    @{ name = "diagram.png"; contentType = "image/png"; storageRef = $uploadResult.storage_ref }
)
```

### Batched questionnaires

For workflows that need multiple related questions answered together (e.g., project kickstart, architecture review), introduce **Questionnaires** — ordered collections of questions delivered as a single unit:

```json
POST /api/questionnaires
{
  "questionnaireId": "qnr-abc123",
  "projectId": "...",
  "title": "Architecture Review — Payment Gateway",
  "description": "Please review and approve these architecture decisions",
  "questions": [
    {
      "questionId": "...",
      "version": 1,
      "order": 1,
      "required": true,
      "dependsOn": null
    },
    {
      "questionId": "...",
      "version": 1,
      "order": 2,
      "required": true,
      "dependsOn": null
    },
    {
      "questionId": "...",
      "version": 1,
      "order": 3,
      "required": false,
      "dependsOn": "q1-option-A"
    }
  ],
  "completionPolicy": "all_required|any_required|majority",
  "deadline": "2026-03-20T00:00:00Z"
}
```

**Questionnaire features:**
- **Ordered presentation** — questions shown in sequence or all at once (configurable)
- **Conditional questions** — `dependsOn` shows question only if a prior answer matches
- **Completion policy** — what constitutes "done" (all required answered, majority voted, etc.)
- **Deadline** — optional cutoff after which unanswered questions are escalated
- **Progress tracking** — Mothership tracks per-question response status
- **Partial responses** — respondents can save progress and return later

**Channel rendering:**
- **Teams/Slack:** Multi-card carousel or threaded messages, one per question
- **Email:** Single email with all questions, magic link to web form for full experience
- **Web:** Multi-step form wizard with progress indicator
- **Jira:** Checklist-style issue with sub-tasks per question

**Outpost-side MCP tools:**
- `questionnaire-create -Title <string> -Questions <array>` — create a batched questionnaire
- `questionnaire-status -QuestionnaireId <string>` — check completion progress
- `questionnaire-results -QuestionnaireId <string>` — get all responses

**Events:**
- `questionnaire.created`, `questionnaire.completed`, `questionnaire.expired`
- `question.answered` (per individual question within a questionnaire)

## Outpost settings evolution

```json
"mothership": {
  "enabled": false,
  "server_url": "",
  "api_key": "",
  "channels": {
    "primary": "teams",
    "fallback": ["email"],
    "per_recipient": {}
  },
  "recipients": [],
  "project_name": "",
  "project_description": "",
  "poll_interval_seconds": 30,
  "sync_tasks": true,
  "sync_questions": true,
  "sync_decisions": true,
  "attachment_max_size_mb": 10
}
```

## Files

**Server-side:**
- Create: `Services/Delivery/SlackDeliveryProvider.cs`
- Create: `Services/Delivery/DiscordDeliveryProvider.cs`
- Create: `Services/Delivery/WhatsAppDeliveryProvider.cs`
- Create: `Services/Delivery/WebDeliveryProvider.cs`
- Create: `Services/AttachmentStorageService.cs`
- Create: `Services/QuestionnaireService.cs`
- Create: `Models/Questionnaire.cs`
- Create: `Models/Attachment.cs`, `Models/ReviewLink.cs`
- Modify: `Models/DeliveryChannelSettings.cs` — add Slack, Discord, WhatsApp settings
- Modify: `Models/QuestionTemplate.cs` — add attachments, review links
- Modify: `Models/CreateInstanceRequest.cs` — per-recipient channel config
- Modify: `Services/Delivery/DeliveryOrchestrator.cs` — multi-channel fallback logic
- Create: `Pages/Questionnaire.cshtml` — multi-question web response form
- Create: API endpoints for questionnaires and attachments

**Outpost-side:**
- Modify: `systems/mcp/tools/task-mark-needs-input/metadata.yaml` — add attachments, review_links params
- Modify: `systems/mcp/tools/task-mark-needs-input/script.ps1` — upload attachments
- Create: `systems/mcp/tools/questionnaire-{create,status,results}/` (3 tools)
- Modify: `systems/mcp/modules/NotificationClient.psm1` / `MothershipClient.psm1` — attachment upload, questionnaire API
- Modify: `profiles/default/defaults/settings.default.json` — channels config
