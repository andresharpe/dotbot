namespace Dotbot.Server.Models;

public class AnswerRecord
{
    public required string QuestionId { get; set; }
    public required string Question { get; set; }
    public required List<QuestionOption> Options { get; set; }
    public required string Answer { get; set; }
    public string AnswerType { get; set; } = "option";
    public string? AnswerKey { get; set; }
    public required string UserId { get; set; }
    public required string UserName { get; set; }

    // For efficient querying/partitioning
    public string? ProjectId { get; set; }

    public DateTime AnsweredAt { get; set; } = DateTime.UtcNow;
}
