namespace Dotbot.Server.Services.Delivery;

public class NotificationSummary
{
    public required string QuestionTitle { get; set; }
    public required string QuestionType { get; set; }
    public required string ProjectName { get; set; }

    public string? DeliverableSummary { get; set; }
    public string? Context { get; set; }

    public List<AttachmentRef> Attachments { get; set; } = new();
    public List<ReviewLinkRef> ReviewLinks { get; set; } = new();

    public required string RespondUrl { get; set; }
    public DateTime? DueBy { get; set; }
    public bool IsReminder { get; set; }

    // Original send time for the recipient — populated by DeliveryOrchestrator on reminder
    // deliveries from InstanceRecipient.SentAt. Providers render it as an "Originally sent:"
    // line alongside the reminder marker (PRD-029 §7). Null on first-time deliveries.
    public DateTime? OriginallySentAt { get; set; }
}

public class AttachmentRef
{
    public required string Name { get; set; }
    public required string ContentType { get; set; }
    public long? SizeBytes { get; set; }
    // No DownloadUrl — channels never link to files. Downloads happen on the web
    // form after the magic link is followed (PRD §4.2).
}

public class ReviewLinkRef
{
    public required string Title { get; set; }
    public required string Url { get; set; }
    public string? Type { get; set; }
}
