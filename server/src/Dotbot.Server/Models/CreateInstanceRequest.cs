namespace Dotbot.Server.Models;

public class CreateInstanceRequest
{
    public Guid InstanceId { get; set; }
    public required string ProjectId { get; set; }
    public required Guid QuestionId { get; set; }
    public required int QuestionVersion { get; set; }

    public string Channel { get; set; } = "teams";
    public string? JiraIssueKey { get; set; }

    public Recipients? Recipients { get; set; }
    public DeliveryOverrides? DeliveryOverrides { get; set; }
    public string? CreatedBy { get; set; }
}

public class Recipients
{
    public List<string>? Emails { get; set; }
    public List<string>? UserObjectIds { get; set; }
    public List<string>? SlackUserIds { get; set; }
}
