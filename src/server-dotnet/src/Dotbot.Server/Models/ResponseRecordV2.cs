namespace Dotbot.Server.Models;

// Storage layer is intentionally decoupled from the SPEC-029 wire envelope.
// The blob stores a flat record of what the submitter sent; the envelope shape
// is assembled on read by EnvelopeAssembler from this blob plus the instance
// blob plus the immutable template bytes. Adding a field here does not require
// touching the wire DTOs and vice-versa.
//
// Removed vs the pre-envelope shape:
//   QuestionVersion - redundant, the QuestionInstance already carries it.
//   AgreesWithFirst - derived at read time, never persisted.
//   Status          - wire-only "submitted" acknowledgement; lives on AnswerDto.
public class ResponseRecordV2
{
    public required Guid ResponseId { get; set; }

    public required Guid InstanceId { get; set; }
    public required Guid QuestionId { get; set; }
    public required string ProjectId { get; set; }

    public DateTime SubmittedAt { get; set; } = DateTime.UtcNow;

    // "outpost" | "mothership". Distinguishes whose surface produced this
    // response; the reminder service uses it (combined with Responder.Email)
    // to suppress reminders that are already answered.
    public string AnsweredVia { get; set; } = "mothership";

    // Responder identity. Either field may be unset (e.g. outpost push-back
    // when no email is known) - see GAP-2 in the design analysis.
    public string? ResponderEmail { get; set; }
    public string? ResponderAadObjectId { get; set; }

    // Type-specific answer payload. Each field is populated by exactly one
    // question type; the others stay null.
    public Guid? SelectedOptionId { get; set; }
    public string? SelectedKey { get; set; }
    public string? SelectedOptionTitle { get; set; }
    public string? FreeText { get; set; }
    public string? ApprovalDecision { get; set; }
    public string? Comment { get; set; }
    public List<Guid>? ReviewedAttachmentIds { get; set; }
    public List<RankedItem>? RankedItems { get; set; }

    // Files the responder uploaded with the submission.
    public List<AttachmentRecord>? Attachments { get; set; }
}
