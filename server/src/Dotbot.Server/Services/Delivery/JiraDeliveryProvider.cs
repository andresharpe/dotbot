using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Services.Delivery;

public class JiraDeliveryProvider : IQuestionDeliveryProvider
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly DeliveryChannelSettings _channelSettings;
    private readonly ILogger<JiraDeliveryProvider> _logger;

    public string ChannelName => "jira";

    public JiraDeliveryProvider(
        IHttpClientFactory httpClientFactory,
        IOptions<DeliveryChannelSettings> channelSettings,
        ILogger<JiraDeliveryProvider> logger)
    {
        _httpClientFactory = httpClientFactory;
        _channelSettings = channelSettings.Value;
        _logger = logger;
    }

    public async Task<DeliveryResult> DeliverAsync(DeliveryContext context, CancellationToken ct)
    {
        var jiraSettings = _channelSettings.Jira;
        if (string.IsNullOrEmpty(jiraSettings.BaseUrl) ||
            string.IsNullOrEmpty(jiraSettings.Username) ||
            string.IsNullOrEmpty(jiraSettings.ApiToken))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = "Jira settings not configured"
            };
        }

        if (string.IsNullOrEmpty(context.JiraIssueKey))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = "No Jira issue key provided"
            };
        }

        var comment = context.Summary is { } summary
            ? BuildJiraCommentFromSummary(summary)
            : BuildJiraComment(context.Template, context.MagicLinkUrl, context.IsReminder);

        var client = _httpClientFactory.CreateClient();
        var authBytes = Encoding.ASCII.GetBytes($"{jiraSettings.Username}:{jiraSettings.ApiToken}");
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Basic", Convert.ToBase64String(authBytes));

        var payload = new { body = comment };
        var json = JsonSerializer.Serialize(payload);
        var url = $"{jiraSettings.BaseUrl.TrimEnd('/')}/rest/api/2/issue/{Uri.EscapeDataString(context.JiraIssueKey)}/comment";

        var response = await client.PostAsync(url,
            new StringContent(json, Encoding.UTF8, "application/json"), ct);

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            _logger.LogError("Failed to post Jira comment to {IssueKey}: {Status} {Body}",
                context.JiraIssueKey, response.StatusCode, body);
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = $"Jira API failed: {response.StatusCode}"
            };
        }

        _logger.LogInformation("Posted question comment to Jira issue {IssueKey}", context.JiraIssueKey);
        return new DeliveryResult { Success = true, Channel = ChannelName };
    }

    internal static string BuildJiraComment(QuestionTemplate template, string? magicLinkUrl, bool isReminder)
    {
        var sb = new StringBuilder();

        if (isReminder)
            sb.AppendLine("{panel:borderColor=#f0ad4e|bgColor=#fff4ce}*Reminder:* This question is still awaiting a response.{panel}");

        sb.AppendLine($"h3. {template.Title}");
        sb.AppendLine();

        if (!string.IsNullOrWhiteSpace(template.Context))
        {
            sb.AppendLine($"_{template.Context}_");
            sb.AppendLine();
        }

        sb.AppendLine("||Option||Description||");
        foreach (var option in template.Options)
        {
            var desc = option.Summary ?? option.Title;
            sb.AppendLine($"|*{option.Key}.* {option.Title}|{desc}|");
        }

        if (!string.IsNullOrEmpty(magicLinkUrl))
        {
            sb.AppendLine();
            sb.AppendLine($"[Respond Now|{magicLinkUrl}]");
        }

        return sb.ToString();
    }

    internal static string BuildJiraCommentFromSummary(NotificationSummary summary)
    {
        var sb = new StringBuilder();

        if (summary.IsReminder)
        {
            sb.AppendLine("{panel:borderColor=#f0ad4e|bgColor=#fff4ce}*Reminder:* This question is still awaiting a response.{panel}");
        }

        sb.AppendLine($"h3. {summary.QuestionTitle}");
        sb.AppendLine();

        sb.AppendLine($"*Project:* {summary.ProjectName} | *Type:* {summary.QuestionType}");
        sb.AppendLine();

        if (!string.IsNullOrWhiteSpace(summary.DeliverableSummary))
        {
            sb.AppendLine(summary.DeliverableSummary);
            sb.AppendLine();
        }

        if (!string.IsNullOrWhiteSpace(summary.Context))
        {
            sb.AppendLine($"_{summary.Context}_");
            sb.AppendLine();
        }

        if (summary.BatchQuestions.Count > 0)
        {
            sb.AppendLine("*Questions in this batch:*");
            foreach (var q in summary.BatchQuestions)
            {
                var prefix = q.IsAnswered ? "✓ " : string.Empty;
                var suffix = (q.IsAnswered && !string.IsNullOrWhiteSpace(q.AnsweredSummary))
                    ? $" — {q.AnsweredSummary}"
                    : string.Empty;
                sb.AppendLine($"* {prefix}{q.Title} _({q.Type})_{suffix}");
            }
            sb.AppendLine();
        }

        if (summary.Attachments.Count > 0)
        {
            sb.AppendLine("*Attachments:*");
            foreach (var a in summary.Attachments)
            {
                sb.AppendLine($"* {a.Name} _({DeliveryFormatting.FormatBytes(a.SizeBytes)})_");
            }
            sb.AppendLine();
        }

        if (summary.ReviewLinks.Count > 0)
        {
            sb.AppendLine("*Review links:*");
            foreach (var r in summary.ReviewLinks)
            {
                sb.AppendLine($"* [{r.Title}|{r.Url}]");
            }
            sb.AppendLine();
        }

        if (summary.DueBy.HasValue)
        {
            sb.AppendLine($"*Due by:* {DeliveryFormatting.FormatUtc(summary.DueBy.Value)}");
            sb.AppendLine();
        }

        sb.AppendLine($"[Respond Now|{summary.RespondUrl}]");

        return sb.ToString();
    }

}
