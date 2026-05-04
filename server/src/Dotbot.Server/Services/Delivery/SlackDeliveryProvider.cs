using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Services.Delivery;

public class SlackDeliveryProvider : IQuestionDeliveryProvider
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly SlackChannelSettings _settings;
    private readonly ILogger<SlackDeliveryProvider> _logger;

    // Cache Slack display names to avoid a users.info call on every delivery
    private readonly ConcurrentDictionary<string, string> _nameCache = new();

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

        var displayName = await ResolveDisplayNameAsync(slackUserId, ct);
        var template = context.Template;

        List<object> blocks;
        string fallbackText;
        if (context.Summary is not null)
        {
            blocks = BuildSummaryBlocks(context.Summary);
            fallbackText = $"{context.Summary.ProjectName}: {context.Summary.QuestionTitle}";
        }
        else
        {
            blocks = BuildBlocks(template, context.MagicLinkUrl, context.IsReminder, displayName);
            fallbackText = $"{template.Project.Name}: {template.Title}";
        }

        var payload = new
        {
            channel = slackUserId,
            text = fallbackText,
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

    private async Task<string?> ResolveDisplayNameAsync(string slackUserId, CancellationToken ct)
    {
        if (_nameCache.TryGetValue(slackUserId, out var cached))
            return cached;

        try
        {
            var client = _httpClientFactory.CreateClient();
            client.DefaultRequestHeaders.Authorization =
                new AuthenticationHeaderValue("Bearer", _settings.BotToken);

            var response = await client.GetAsync(
                $"https://slack.com/api/users.info?user={Uri.EscapeDataString(slackUserId)}", ct);

            var body = await response.Content.ReadAsStringAsync(ct);
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;

            if (!root.TryGetProperty("ok", out var okProp) || !okProp.GetBoolean())
            {
                _logger.LogWarning("users.info failed for {UserId}: {Body}", slackUserId, body);
                return null;
            }

            var profile = root.GetProperty("user").GetProperty("profile");

            // Prefer first_name, fall back to display_name, then real_name
            var name =
                TryGetString(profile, "first_name") ??
                TryGetString(profile, "display_name") ??
                TryGetString(profile, "real_name");

            if (!string.IsNullOrWhiteSpace(name))
                _nameCache[slackUserId] = name;

            return name;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not resolve display name for Slack user {UserId}", slackUserId);
            return null;
        }
    }

    private static string? TryGetString(JsonElement element, string property) =>
        element.TryGetProperty(property, out var prop) && prop.ValueKind == JsonValueKind.String
            ? prop.GetString() is { Length: > 0 } s ? s : null
            : null;

    internal static List<object> BuildBlocks(QuestionTemplate template, string? magicLinkUrl, bool isReminder, string? displayName)
    {
        var blocks = new List<object>();

        // Reminder banner
        if (isReminder)
        {
            blocks.Add(new
            {
                type = "context",
                elements = new[] { new { type = "mrkdwn", text = ":wave: *Reminder* — this question is still waiting for your response." } }
            });
        }

        // Question title 
        var title = string.IsNullOrWhiteSpace(template.Title) ? "Input needed" : template.Title;
        var firstName = ExtractFirstName(displayName);
        var personalised = !string.IsNullOrWhiteSpace(firstName) && firstName != "there";
        var headerText = personalised
            ? $"Hi {firstName}, {char.ToLower(title[0])}{title[1..]}"
            : title;

        blocks.Add(new
        {
            type = "header",
            text = new { type = "plain_text", text = headerText.Length <= 150 ? headerText : title, emoji = false }
        });

        // Project + context as a compact metadata line
        var metaParts = new List<string>();
        if (!string.IsNullOrWhiteSpace(template.Project.Name))
            metaParts.Add($":robot_face: {Escape(template.Project.Name)}");
        if (!string.IsNullOrWhiteSpace(template.Project.Description))
            metaParts.Add(Escape(template.Project.Description));

        if (metaParts.Count > 0)
        {
            blocks.Add(new
            {
                type = "context",
                elements = new[] { new { type = "mrkdwn", text = string.Join("  ·  ", metaParts) } }
            });
        }

        // Context paragraph
        if (!string.IsNullOrWhiteSpace(template.Context))
        {
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = Escape(template.Context) }
            });
        }

        // Options — compact single block, just enough to inform the decision
        var optionsText = new StringBuilder();
        foreach (var option in template.Options)
        {
            optionsText.Append(option.IsRecommended
                ? $"*{Escape(option.Key)}*  {Escape(option.Title)} ✅"
                : $"*{Escape(option.Key)}*  {Escape(option.Title)}");
            if (!string.IsNullOrWhiteSpace(option.Summary))
                optionsText.Append($"  —  _{Escape(option.Summary)}_");
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

    // Escape a label rendered inside Slack <url|label> link syntax. `|` and `>` terminate the
    // label; both are replaced by HTML-style entities Slack renders verbatim.
    private static string EscapeLinkLabel(string value) =>
        Escape(value).Replace("|", "&#124;");

    // Escape a value rendered inside a Slack code-span (`...`). A backtick terminates the span,
    // re-enabling mrkdwn formatting on the surrounding text. No HTML entity exists for backtick
    // inside a code-span; substitute the visually similar U+02CB (modifier letter grave accent).
    private static string EscapeCodeSpan(string value) =>
        Escape(value).Replace("`", "ˋ");

    public static List<object> BuildSummaryBlocks(NotificationSummary summary)
    {
        var blocks = new List<object>();

        // Reminder banner — pre-pends the card so re-deliveries are immediately visible
        if (summary.IsReminder)
        {
            blocks.Add(new
            {
                type = "context",
                elements = new[] { new { type = "mrkdwn", text = ":alarm_clock: *Reminder* — this question is still awaiting your response." } }
            });
        }

        blocks.Add(new
        {
            type = "header",
            text = new { type = "plain_text", text = Truncate(summary.QuestionTitle, 150), emoji = false }
        });

        var meta = new List<string>
        {
            $":robot_face: {Escape(summary.ProjectName)}",
            $"`{EscapeCodeSpan(summary.QuestionType)}`"
        };
        blocks.Add(new
        {
            type = "context",
            elements = new[] { new { type = "mrkdwn", text = string.Join("  ·  ", meta) } }
        });

        if (summary.DueBy.HasValue)
        {
            blocks.Add(new
            {
                type = "context",
                elements = new[] { new { type = "mrkdwn", text = $"*Due by:* {DeliveryFormatting.FormatUtc(summary.DueBy.Value)}" } }
            });
        }

        if (!string.IsNullOrWhiteSpace(summary.DeliverableSummary))
        {
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = $"*Summary*\n{Escape(summary.DeliverableSummary)}" }
            });
        }

        if (!string.IsNullOrWhiteSpace(summary.Context))
        {
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = Escape(summary.Context) }
            });
        }

        if (summary.BatchQuestions.Count > 0)
        {
            var sb = new StringBuilder("*Questions in this batch*\n");
            foreach (var q in summary.BatchQuestions)
            {
                if (q.IsAnswered)
                {
                    var ans = !string.IsNullOrWhiteSpace(q.AnsweredSummary)
                        ? $" — _{Escape(q.AnsweredSummary)}_"
                        : "";
                    sb.AppendLine($"✓ {Escape(q.Title)} (`{EscapeCodeSpan(q.Type)}`){ans}");
                }
                else
                {
                    sb.AppendLine($"• {Escape(q.Title)} (`{EscapeCodeSpan(q.Type)}`)");
                }
            }
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = sb.ToString().TrimEnd() }
            });
        }

        if (summary.Attachments.Count > 0)
        {
            var sb = new StringBuilder("*Attachments*\n");
            foreach (var a in summary.Attachments)
            {
                sb.AppendLine($"• {Escape(a.Name)} ({DeliveryFormatting.FormatBytes(a.SizeBytes)})");
            }
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = sb.ToString().TrimEnd() }
            });
        }

        if (summary.ReviewLinks.Count > 0)
        {
            var sb = new StringBuilder("*Review links*\n");
            foreach (var link in summary.ReviewLinks)
            {
                // Skip non-absolute or non-http(s) URLs to block scheme spoofing (javascript:,
                // data:, etc.) and parity with Teams card validation.
                if (!Uri.TryCreate(link.Url, UriKind.Absolute, out var linkUri) ||
                    (linkUri.Scheme != Uri.UriSchemeHttp && linkUri.Scheme != Uri.UriSchemeHttps))
                {
                    continue;
                }

                var marker = !string.IsNullOrWhiteSpace(link.Type) ? " _(requires review)_" : "";
                sb.AppendLine($"• <{linkUri.AbsoluteUri}|{EscapeLinkLabel(link.Title)}>{marker}");
            }
            blocks.Add(new
            {
                type = "section",
                text = new { type = "mrkdwn", text = sb.ToString().TrimEnd() }
            });
        }

        blocks.Add(new
        {
            type = "actions",
            elements = new[]
            {
                new
                {
                    type = "button",
                    text = new { type = "plain_text", text = "Respond Now", emoji = false },
                    url = summary.RespondUrl,
                    style = "primary"
                }
            }
        });

        return blocks;
    }

    private static string Truncate(string s, int max) =>
        string.IsNullOrEmpty(s) ? s : (s.Length <= max ? s : s.Substring(0, max));
}
