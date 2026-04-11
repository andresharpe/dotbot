namespace Dotbot.Server.Models;

public class QuestionOption
{
    public required string Key { get; set; }
    public required string Label { get; set; }
    public string? Rationale { get; set; }
    public Guid? OptionId { get; set; }
}
