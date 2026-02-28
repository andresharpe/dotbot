namespace Dotbot.Server.Models;

public class QuestionPayload
{
    public required string QuestionId { get; set; }
    public required string Question { get; set; }
    public string? Context { get; set; }
    public required List<QuestionOption> Options { get; set; }
    public string Recommendation { get; set; } = "A";
    public required string UserObjectId { get; set; }
    public bool AllowFreeText { get; set; }

    // Optional but recommended for partitioning and lookup
    public string? ProjectId { get; set; }
    public string? ProjectName { get; set; }
    public string? ProjectDescription { get; set; }
}

public class QuestionOption
{
    public required string Key { get; set; }
    public required string Label { get; set; }
    public string? Rationale { get; set; }
    public Guid? OptionId { get; set; }
}
