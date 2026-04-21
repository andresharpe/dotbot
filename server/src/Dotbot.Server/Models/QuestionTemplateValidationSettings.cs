namespace Dotbot.Server.Models;

public class QuestionTemplateValidationSettings
{
    public const int DefaultMaxAttachments = 20;
    public const int DefaultMaxReferenceLinks = 20;

    public int MaxAttachments { get; set; } = DefaultMaxAttachments;
    public int MaxReferenceLinks { get; set; } = DefaultMaxReferenceLinks;
}
