using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dotbot.Server.Models.Envelope;

// SPEC-029 envelope contract - the OUTPOST-facing wire shape. These are transfer
// types only; none are persisted whole. The server stores minimal blobs (question,
// instance envelope parts, ResponseRecordV2) and assembles an EnvelopeMessage on read.
//
// One message type serves every endpoint in both directions. Each endpoint reads the
// sections it needs and ignores the rest:
//   POST /api/templates  -> envelope + question
//   POST /api/instances  -> envelope + question(.questionId) + recipients
//   POST /api/responses  -> envelope + answer + responder
//   GET  .../responses   -> [ envelope + question + answer + responder ]
//   GET  instance record -> envelope + question + recipients

public sealed class EnvelopeMessage
{
    public EnvelopeDto Envelope { get; set; } = new();

    // The question block IS the published QuestionTemplate JSON, carried verbatim as
    // a JsonElement so unknown forward-compatible fields ride along untouched.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public JsonElement? Question { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<InstanceRecipient>? Recipients { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public AnswerDto? Answer { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ResponderDto? Responder { get; set; }
}

public sealed class EnvelopeDto
{
    public Guid OutpostInstanceId { get; set; }
    public string? TaskId { get; set; }
    public string? MothershipUrl { get; set; }

    // Per-delivery instance id. Maps to the existing QuestionInstance.InstanceId.
    public Guid QuestionInstanceId { get; set; }
    public string? ProjectId { get; set; }

    // Delivery routing for the jira channel - which issue to file the question
    // against. Same category as the other routing metadata, so it lives on the
    // envelope. Present only on instance-create when the channel is jira.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? JiraIssueKey { get; set; }

    // UTC ISO 8601 with explicit Z (sec.5.5). Kept as string so a local-time value
    // can be detected and rejected at the boundary rather than silently coerced.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SentAt { get; set; }

    // Response records only.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Guid? ResponseId { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SubmittedAt { get; set; }

    // "outpost" | "mothership".
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AnsweredVia { get; set; }

    // Server-derived at read time (compare to earliest response for the pair).
    // Never stored on a blob.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? AgreesWithFirst { get; set; }
}

public sealed class AnswerDto
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Guid? SelectedOptionId { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SelectedKey { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SelectedOptionTitle { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? FreeText { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ApprovalDecision { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Comment { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<Guid>? ReviewedAttachmentIds { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<RankedItem>? RankedItems { get; set; }

    // Files attached by the responder. Wire keeps blobPath (the outpost downloads via
    // it and the server resolves /api/attachments by it - see the spec-sync deviation).
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<AttachmentRecord>? Attachments { get; set; }

    public string Status { get; set; } = "submitted";
}

public sealed class ResponderDto
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Email { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AadObjectId { get; set; }
}
