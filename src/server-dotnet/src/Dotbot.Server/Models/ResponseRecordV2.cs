namespace Dotbot.Server.Models;

public class ResponseRecordV2
{
    public required Guid ResponseId { get; set; }

    public required Guid InstanceId { get; set; }
    public required Guid QuestionId { get; set; }
    public required int QuestionVersion { get; set; }
    public required string ProjectId { get; set; }

    public string? ResponderEmail { get; set; }
    public string? ResponderAadObjectId { get; set; }

    public Guid? SelectedOptionId { get; set; }
    public string? SelectedKey { get; set; }
    public string? SelectedOptionTitle { get; set; }
    public string? FreeText { get; set; }
    public List<AttachmentRecord>? Attachments { get; set; }

    public DateTime SubmittedAt { get; set; } = DateTime.UtcNow;
    public string Status { get; set; } = "submitted";

    public string? ApprovalDecision { get; set; }
    public string? Comment { get; set; }
    public List<Guid>? ReviewedAttachmentIds { get; set; }
    public List<RankedItem>? RankedItems { get; set; }
}
