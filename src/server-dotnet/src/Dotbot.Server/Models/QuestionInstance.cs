namespace Dotbot.Server.Models;

public class QuestionInstance
{
    public required Guid InstanceId { get; set; }
    public required Guid QuestionId { get; set; }
    public required int QuestionVersion { get; set; }
    public required string ProjectId { get; set; }

    public List<InstanceRecipient> SentTo { get; set; } = new();

    public DeliveryOverrides? DeliveryOverrides { get; set; }
    public string OverallStatus { get; set; } = "active";

    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public string? CreatedBy { get; set; }
}

public class InstanceRecipient
{
    public string? Email { get; set; }
    public string? AadObjectId { get; set; }
    public string? SlackUserId { get; set; }
    public string Channel { get; set; } = "teams";
    public DateTime? SentAt { get; set; }
    public string Status { get; set; } = "pending"; // pending | scheduled | sent | reminded | escalated | failed
    public DateTime? ScheduledAt { get; set; }
    public DateTime? LastReminderAt { get; set; }
    public DateTime? EscalatedAt { get; set; }
}

public class DeliveryOverrides
{
    public int? ReminderAfterHours { get; set; }
    public int? EscalateAfterDays { get; set; }
}
