namespace Dotbot.Server.Models;

public class QuestionTemplate
{
    public required Guid QuestionId { get; set; }
    public string? Code { get; set; }
    public required int Version { get; set; }

    public string Type { get; set; } = "singleChoice";

    public required string Title { get; set; }
    public string? Description { get; set; }
    public string? Context { get; set; }

    public required List<TemplateOption> Options { get; set; }

    public ResponseSettings? ResponseSettings { get; set; }
    public DeliveryDefaults? DeliveryDefaults { get; set; }

    public required ProjectRef Project { get; set; }

    public string Status { get; set; } = "published";
    public DateTime? CreatedAt { get; set; }
    public string? CreatedBy { get; set; }

    public List<QuestionAttachment>? Attachments { get; set; }
    public List<ReferenceLink>? ReferenceLinks { get; set; }
    public string? DeliverableSummary { get; set; }
}

public class TemplateOption
{
    public required Guid OptionId { get; set; }
    public required string Key { get; set; }
    public required string Title { get; set; }
    public string? Summary { get; set; }
    public OptionDetails? Details { get; set; }
    public bool IsRecommended { get; set; }
}

public class OptionDetails
{
    public string? Overview { get; set; }
    public List<string>? Pros { get; set; }
    public List<string>? Cons { get; set; }
    public string? RiskLevel { get; set; }
    public string? ImplementationEffort { get; set; }
}

public class ResponseSettings
{
    public bool MultiSelect { get; set; }
    public bool AllowFreeText { get; set; }
    public bool FreeTextRequired { get; set; }
    public string? FreeTextLabel { get; set; }
}

public class DeliveryDefaults
{
    public int? ReminderAfterHours { get; set; }
    public int? EscalateAfterDays { get; set; }
    public string? Priority { get; set; }
}

public class ProjectRef
{
    public required string ProjectId { get; set; }
    public string? Name { get; set; }
    public string? Description { get; set; }
}
