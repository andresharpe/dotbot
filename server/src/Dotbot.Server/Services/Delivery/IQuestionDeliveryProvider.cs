using Dotbot.Server.Models;

namespace Dotbot.Server.Services.Delivery;

public interface IQuestionDeliveryProvider
{
    string ChannelName { get; }
    Task<DeliveryResult> DeliverAsync(DeliveryContext context, CancellationToken ct);
}

public class DeliveryContext
{
    public required QuestionInstance Instance { get; set; }
    public required QuestionTemplate Template { get; set; }
    public required RecipientInfo Recipient { get; set; }
    public bool IsReminder { get; set; }
    public string? MagicLinkUrl { get; set; }
    public string? JiraIssueKey { get; set; }
}

public class RecipientInfo
{
    public required string Email { get; set; }
    public string? AadObjectId { get; set; }
    public string? DisplayName { get; set; }
    public string? SlackUserId { get; set; }
}

public class DeliveryResult
{
    public bool Success { get; set; }
    public string? ErrorMessage { get; set; }
    public required string Channel { get; set; }
}
