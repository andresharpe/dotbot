using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Services.Delivery;

public class SlackDeliveryProvider : IQuestionDeliveryProvider
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly SlackChannelSettings _settings;
    private readonly ILogger<SlackDeliveryProvider> _logger;

    public string ChannelName => "slack";

    public SlackDeliveryProvider(
        IHttpClientFactory httpClientFactory,
        IOptions<DeliveryChannelSettings> channelSettings,
        ILogger<SlackDeliveryProvider> logger)
    {
        _httpClientFactory = httpClientFactory;
        _settings = channelSettings.Value.Slack;
        _logger = logger;
    }

    public async Task<DeliveryResult> DeliverAsync(DeliveryContext context, CancellationToken ct)
    {
        var slackUserId = context.Recipient.SlackUserId;
        if (string.IsNullOrEmpty(slackUserId))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = "No Slack user ID for recipient"
            };
        }

        if (string.IsNullOrEmpty(_settings.BotToken))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = "Slack bot token not configured"
            };
        }

        var template = context.Template;
        var blocks = BuildBlocks(template, context.MagicLinkUrl, context.IsReminder, context.Recipient.DisplayName);

        var payload = new
        {
            channel = slackUserId,
            text = $"{template.Project.Name}: {template.Title}",
            blocks
        };

        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        });

        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", _settings.BotToken);

        var response = await client.PostAsync(
            "https://slack.com/api/chat.postMessage",
            new StringContent(json, Encoding.UTF8, "application/json"),
            ct);

        var responseBody = await response.Content.ReadAsStringAsync(ct);

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError("Slack API HTTP error for {UserId}: {Status} {Body}",
                slackUserId, response.StatusCode, responseBody);
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = $"Slack API HTTP error: {response.StatusCode}"
            };
        }

        using var doc = JsonDocument.Parse(responseBody);
        var ok = doc.RootElement.TryGetProperty("ok", out var okProp) && okProp.GetBoolean();
        if (!ok)
        {
            var error = doc.RootElement.TryGetProperty("error", out var errProp)
                ? errProp.GetString()
                : "unknown_error";
            _logger.LogError("Slack API error for {UserId}: {Error}", slackUserId, error);
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = $"Slack API error: {error}"
            };
        }

        _logger.LogInformation("Delivered question to Slack user {UserId} for instance {InstanceId}",
            slackUserId, context.Instance.InstanceId);
        return new DeliveryResult { Success = true, Channel = ChannelName };
    }

    private static List<object> BuildBlocks(QuestionTemplate template, string? magicLinkUrl, bool isReminder, string? displayName)
    {
        var blocks = new List<object>();

        // Reminder banner
        if (isReminder)
        {
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = ":warning: *Reminder:* This question is still awaiting your response." }
            });
            blocks.Add(new { type = "divider" });
        }

        // Project header
        if (!string.IsNullOrWhiteSpace(template.Project.Name))
        {
            var projectText = $"*{Escape(template.Project.Name)}*";
            if (!string.IsNullOrWhiteSpace(template.Project.Description))
                projectText += $"\n{Escape(template.Project.Description)}";

            blocks.Add(new
            {
                type = "context",
                elements = new[] { new { type = "mrkdwn", text = projectText } }
            });
        }

        // Greeting + question title
        var firstName = ExtractFirstName(displayName);
        var headerText = $"Hi {Escape(firstName)}, we need your expertise to help advance the project.\n\n*{Escape(template.Title)}*";
        blocks.Add(new
        {
            type = "section",
            text = new { type = "mrkdwn", text = headerText }
        });

        // Context
        if (!string.IsNullOrWhiteSpace(template.Context))
        {
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = Escape(template.Context) }
            });
        }

        blocks.Add(new { type = "divider" });

        // Options
        var optionsText = new StringBuilder();
        foreach (var option in template.Options)
        {
            optionsText.Append($"*{Escape(option.Key)}*  {Escape(option.Title)}");
            if (!string.IsNullOrWhiteSpace(option.Summary))
                optionsText.Append($"\n_{Escape(option.Summary)}_");
            optionsText.AppendLine();
        }

        blocks.Add(new
        {
            type = "section",
            text = new { type = "mrkdwn", text = optionsText.ToString().TrimEnd() }
        });

        // Respond Now button
        if (!string.IsNullOrEmpty(magicLinkUrl))
        {
            blocks.Add(new
            {
                type = "actions",
                elements = new[]
                {
                    new
                    {
                        type = "button",
                        text = new { type = "plain_text", text = "Respond Now", emoji = false },
                        url = magicLinkUrl,
                        style = "primary"
                    }
                }
            });
        }

        return blocks;
    }

    private static string ExtractFirstName(string? displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName))
            return "there";
        var name = displayName.Trim();
        if (name.Contains(','))
        {
            var parts = name.Split(',', 2);
            var afterComma = parts[1].Trim();
            return string.IsNullOrEmpty(afterComma) ? name : afterComma.Split(' ')[0];
        }
        return name.Split(' ')[0];
    }

    // Escape Slack mrkdwn special characters in plain text values
    private static string Escape(string value) =>
        value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}
