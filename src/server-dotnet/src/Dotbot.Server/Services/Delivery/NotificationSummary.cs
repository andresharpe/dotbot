namespace Dotbot.Server.Services.Delivery;

public class NotificationSummary
{
    public required string QuestionTitle { get; set; }
    public required string QuestionType { get; set; }
    public required string ProjectName { get; set; }

    public string? DeliverableSummary { get; set; }
    public string? Context { get; set; }

    // All questions in the current instance's batch, each with its state.
    // Outpost groups questions when calling task-mark-needs-input; single-question
    // instance → one entry. No cross-instance lookup.
    public List<BatchQuestionRef> BatchQuestions { get; set; } = new();

    public List<AttachmentRef> Attachments { get; set; } = new();
    public List<ReviewLinkRef> ReviewLinks { get; set; } = new();

    public required string RespondUrl { get; set; }
    public DateTime? DueBy { get; set; }
    public bool IsReminder { get; set; }
}

public class BatchQuestionRef
{
    public required Guid QuestionId { get; set; }
    public required string Title { get; set; }
    public required string Type { get; set; }

    // Populated by the PR introducing multi-question batches (#289). Until then,
    // builder leaves these at default — single-question instances never carry an
    // already-answered question (reminders suppress those, see #290).
    public bool IsAnswered { get; set; }
    public string? AnsweredSummary { get; set; }
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
