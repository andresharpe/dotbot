using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Services.Delivery;

public class EmailDeliveryProvider : IQuestionDeliveryProvider
{
    private readonly GraphTokenService _graphTokenService;
    private readonly DeliveryChannelSettings _channelSettings;
    private readonly ILogger<EmailDeliveryProvider> _logger;

    public string ChannelName => "email";

    public EmailDeliveryProvider(
        GraphTokenService graphTokenService,
        IOptions<DeliveryChannelSettings> channelSettings,
        ILogger<EmailDeliveryProvider> logger)
    {
        _graphTokenService = graphTokenService;
        _channelSettings = channelSettings.Value;
        _logger = logger;
    }

    public async Task<DeliveryResult> DeliverAsync(DeliveryContext context, CancellationToken ct)
    {
        var senderAddress = _channelSettings.Email.SenderAddress;
        if (string.IsNullOrEmpty(senderAddress))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = "Email sender address not configured"
            };
        }

        var template = context.Template;
        var summary = context.Summary;

        var htmlBody = summary is not null
            ? BuildEmailHtmlFromSummary(summary, context.Recipient.DisplayName)
            : BuildEmailHtml(template, context.MagicLinkUrl, context.IsReminder, context.Recipient.DisplayName);

        var subjectProject = summary?.ProjectName ?? template.Project.Name;
        var subjectTitle = summary?.QuestionTitle ?? template.Title;
        var subjectIsReminder = summary?.IsReminder ?? context.IsReminder;
        var subject = subjectIsReminder
            ? $"[Reminder] {subjectProject}: {subjectTitle}"
            : $"{subjectProject}: {subjectTitle}";

        var mailPayload = new
        {
            message = new
            {
                subject,
                body = new
                {
                    contentType = "HTML",
                    content = htmlBody
                },
                toRecipients = new[]
                {
                    new
                    {
                        emailAddress = new
                        {
                            address = context.Recipient.Email,
                            name = context.Recipient.DisplayName ?? context.Recipient.Email
                        }
                    }
                },
                from = new
                {
                    emailAddress = new
                    {
                        address = senderAddress,
                        name = _channelSettings.Email.SenderDisplayName
                    }
                }
            },
            saveToSentItems = false
        };

        var client = await _graphTokenService.CreateAuthenticatedClientAsync();
        var json = JsonSerializer.Serialize(mailPayload, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        });

        var response = await client.PostAsync(
            $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(senderAddress)}/sendMail",
            new StringContent(json, Encoding.UTF8, "application/json"),
            ct);

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            _logger.LogError("Failed to send email to {Email}: {Status} {Body}",
                context.Recipient.Email, response.StatusCode, body);
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = $"Graph sendMail failed: {response.StatusCode}"
            };
        }

        _logger.LogInformation("Sent email to {Email} for instance {InstanceId}",
            context.Recipient.Email, context.Instance.InstanceId);
        return new DeliveryResult { Success = true, Channel = ChannelName };
    }

    internal static string BuildEmailHtml(QuestionTemplate template, string? magicLinkUrl, bool isReminder, string? recipientDisplayName)
    {
        var firstName = ExtractFirstName(recipientDisplayName);
        var sb = new StringBuilder();

        // DOCTYPE + HTML head with Outlook VML namespaces and mobile meta
        sb.Append("""
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
            <head>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <!--[if gte mso 9]>
            <xml>
            <o:OfficeDocumentSettings>
            <o:AllowPNG/>
            <o:PixelsPerInch>96</o:PixelsPerInch>
            </o:OfficeDocumentSettings>
            </xml>
            <![endif]-->
            <style type="text/css">
            body, table, td { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; }
            table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; }
            @media only screen and (max-width: 600px) {
                .container { padding: 16px !important; }
                .panel { border-width: 0 !important; }
            }
            </style>
            </head>
            """);

        // Body — light theme so Outlook dark mode naturally inverts to dark
        sb.Append("""
            <body style="margin: 0; padding: 0; background-color: #F0F0F4; width: 100%;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color: #F0F0F4;">
            <tr><td align="center" style="padding: 32px 16px;" class="container">
            """);

        // MSO conditional wrapper for fixed 600px width in Outlook
        sb.Append("""
            <!--[if mso]>
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" align="center"><tr><td>
            <![endif]-->
            """);

        // Main panel container
        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width: 600px; background-color: #FFFFFF; border: 1px solid #E2E2EA; border-collapse: collapse;" class="panel">
            <tr><td style="padding: 32px;">
            """);

        // Reminder banner (conditional)
        if (isReminder)
        {
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="background-color: #FFF8E8; border: 1px solid #E8A030; padding: 12px 16px; font-family: Inter, Arial, sans-serif; font-size: 14px; color: #E8A030;">
                <strong>&#9888; Reminder:</strong> This question is still awaiting your response.
                </td></tr></table>
                """);

            // Spacer: reminder → project banner
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="height:24px; line-height:24px; font-size:1px;">&nbsp;</td></tr>
                </table>
                """);
        }

        // Project banner with amber left accent
        if (!string.IsNullOrWhiteSpace(template.Project.Name))
        {
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                """);

            // MSO: use table cell for left border accent
            sb.Append("""
                <!--[if mso]>
                <td width="4" style="background-color: #B87820;"></td>
                <td style="background-color: #F5F4F0; padding: 12px 16px;">
                <![endif]-->
                <!--[if !mso]><!-->
                <td style="background-color: #F5F4F0; border-left: 4px solid #B87820; padding: 12px 16px;">
                <!--<![endif]-->
                """);

            sb.Append($"""
                <span style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 14px; font-weight: 700; color: #B87820;">{Encode(template.Project.Name)}</span>
                """);
            if (!string.IsNullOrWhiteSpace(template.Project.Description))
                sb.Append($"""
                    <br/><span style="font-family: Inter, Arial, sans-serif; font-size: 13px; color: #666677;">{Encode(template.Project.Description)}</span>
                    """);

            sb.Append("</td></tr></table>");

            // Spacer: project banner → greeting
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="height:24px; line-height:24px; font-size:1px;">&nbsp;</td></tr>
                </table>
                """);
        }

        // Greeting
        sb.Append($"""
            <p style="font-family: Inter, Arial, sans-serif; font-size: 16px; color: #E8A030; margin: 0 0 4px;">Hi {Encode(firstName)},</p>
            <p style="font-family: Inter, Arial, sans-serif; font-size: 14px; color: #666677; margin: 0 0 24px;">We need your expertise to help advance the project.</p>
            """);

        // Question title
        sb.Append($"""
            <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 18px; font-weight: 700; color: #E8A030; margin: 0 0 16px;">{Encode(template.Title)}</p>
            """);

        // Context (optional)
        if (!string.IsNullOrWhiteSpace(template.Context))
        {
            sb.Append($"""
                <p style="font-family: Inter, Arial, sans-serif; font-size: 14px; color: #666677; margin: 0 0 24px; line-height: 1.5;">{Encode(template.Context)}</p>
                """);
        }

        // Options table
        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse: collapse;">
            """);

        foreach (var option in template.Options)
        {
            sb.Append($"""
                <tr>
                <td style="background-color: #F5F4F0; padding: 10px 14px; border: 1px solid #E2E2EA; vertical-align: top; width: 60px; font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 14px; font-weight: 700; color: #E8A030;">{Encode(option.Key)}</td>
                <td style="padding: 10px 14px; border: 1px solid #E2E2EA; vertical-align: top;">
                <span style="font-family: Inter, Arial, sans-serif; font-size: 14px; font-weight: 600; color: #1A1B2E;">{Encode(option.Title)}</span>
                """);

            if (!string.IsNullOrWhiteSpace(option.Summary))
                sb.Append($"""
                    <br/><span style="font-family: Inter, Arial, sans-serif; font-size: 13px; color: #666677;">{Encode(option.Summary)}</span>
                    """);

            sb.Append("</td></tr>");
        }
        sb.Append("</table>");

        // Spacer: options table → CTA button
        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
            <tr><td style="height:28px; line-height:28px; font-size:1px;">&nbsp;</td></tr>
            </table>
            """);

        // CTA button
        if (!string.IsNullOrEmpty(magicLinkUrl))
        {
            var encodedUrl = Encode(magicLinkUrl);

            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td align="center">
                """);

            // VML button for Outlook
            sb.Append($"""
                <!--[if mso]>
                <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{encodedUrl}" style="height:48px;v-text-anchor:middle;width:220px;" arcsize="10%" strokecolor="#E8A030" fillcolor="#E8A030">
                <w:anchorlock/>
                <center style="font-family:Inter,Arial,sans-serif;font-size:16px;font-weight:700;color:#1A1B2E;">Respond Now</center>
                </v:roundrect>
                <![endif]-->
                <!--[if !mso]><!-->
                <a href="{encodedUrl}" style="display: inline-block; padding: 14px 48px; background-color: #E8A030; color: #1A1B2E; text-decoration: none; border-radius: 6px; font-family: Inter, Arial, sans-serif; font-size: 16px; font-weight: 700; line-height: 20px; text-align: center; mso-hide: all;">Respond Now</a>
                <!--<![endif]-->
                """);

            sb.Append("</td></tr></table>");

            // Spacer: CTA button → footer
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="height:28px; line-height:28px; font-size:1px;">&nbsp;</td></tr>
                </table>
                """);
        }

        // Footer
        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
            <tr><td style="border-top: 1px solid #E2E2EA; padding-top: 20px;">
            <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 12px; color: #666677; margin: 0; text-align: center;">Dotbot Question System</p>
            </td></tr></table>
            """);

        // Close panel, MSO wrapper, body wrapper
        sb.Append("""
            </td></tr></table>
            <!--[if mso]>
            </td></tr></table>
            <![endif]-->
            </td></tr></table>
            </body>
            </html>
            """);

        return sb.ToString();
    }

    internal static string BuildEmailHtmlFromSummary(NotificationSummary summary, string? recipientDisplayName)
    {
        var firstName = ExtractFirstName(recipientDisplayName);
        var sb = new StringBuilder();

        // DOCTYPE + HTML head — verbatim from BuildEmailHtml so Outlook scaffolding is identical.
        sb.Append("""
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
            <head>
            <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <!--[if gte mso 9]>
            <xml>
            <o:OfficeDocumentSettings>
            <o:AllowPNG/>
            <o:PixelsPerInch>96</o:PixelsPerInch>
            </o:OfficeDocumentSettings>
            </xml>
            <![endif]-->
            <style type="text/css">
            body, table, td { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; }
            table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; }
            @media only screen and (max-width: 600px) {
                .container { padding: 16px !important; }
                .panel { border-width: 0 !important; }
            }
            </style>
            </head>
            """);

        sb.Append("""
            <body style="margin: 0; padding: 0; background-color: #F0F0F4; width: 100%;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color: #F0F0F4;">
            <tr><td align="center" style="padding: 32px 16px;" class="container">
            """);

        sb.Append("""
            <!--[if mso]>
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" align="center"><tr><td>
            <![endif]-->
            """);

        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width: 600px; background-color: #FFFFFF; border: 1px solid #E2E2EA; border-collapse: collapse;" class="panel">
            <tr><td style="padding: 32px;">
            """);

        // Reminder banner
        if (summary.IsReminder)
        {
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="background-color: #FFF8E8; border: 1px solid #E8A030; padding: 12px 16px; font-family: Inter, Arial, sans-serif; font-size: 14px; color: #E8A030;">
                <strong>&#9888; Reminder:</strong> This question is still awaiting your response.
                </td></tr></table>
                """);
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="height:24px; line-height:24px; font-size:1px;">&nbsp;</td></tr>
                </table>
                """);
        }

        // Project banner — Summary carries no description, so single-line variant.
        if (!string.IsNullOrWhiteSpace(summary.ProjectName))
        {
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                """);
            sb.Append("""
                <!--[if mso]>
                <td width="4" style="background-color: #B87820;"></td>
                <td style="background-color: #F5F4F0; padding: 12px 16px;">
                <![endif]-->
                <!--[if !mso]><!-->
                <td style="background-color: #F5F4F0; border-left: 4px solid #B87820; padding: 12px 16px;">
                <!--<![endif]-->
                """);
            sb.Append($"""
                <span style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 14px; font-weight: 700; color: #B87820;">{Encode(summary.ProjectName)}</span>
                """);
            sb.Append("</td></tr></table>");
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="height:24px; line-height:24px; font-size:1px;">&nbsp;</td></tr>
                </table>
                """);
        }

        // Greeting
        sb.Append($"""
            <p style="font-family: Inter, Arial, sans-serif; font-size: 16px; color: #E8A030; margin: 0 0 4px;">Hi {Encode(firstName)},</p>
            <p style="font-family: Inter, Arial, sans-serif; font-size: 14px; color: #666677; margin: 0 0 24px;">We need your expertise to help advance the project.</p>
            """);

        // Question title + type badge
        sb.Append($"""
            <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 18px; font-weight: 700; color: #E8A030; margin: 0 0 16px;">{Encode(summary.QuestionTitle)} <span style="display: inline-block; padding: 2px 8px; background-color: #F5F4F0; border: 1px solid #E2E2EA; border-radius: 4px; font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 11px; font-weight: 600; color: #666677; text-transform: uppercase; letter-spacing: 0.5px; vertical-align: middle;">{Encode(summary.QuestionType)}</span></p>
            """);

        // Deliverable summary (prominent)
        if (!string.IsNullOrWhiteSpace(summary.DeliverableSummary))
        {
            sb.Append($"""
                <p style="font-family: Inter, Arial, sans-serif; font-size: 15px; font-weight: 600; color: #1A1B2E; margin: 0 0 16px; line-height: 1.5;">{Encode(summary.DeliverableSummary)}</p>
                """);
        }

        // Context (secondary)
        if (!string.IsNullOrWhiteSpace(summary.Context))
        {
            sb.Append($"""
                <p style="font-family: Inter, Arial, sans-serif; font-size: 14px; color: #666677; margin: 0 0 24px; line-height: 1.5;">{Encode(summary.Context)}</p>
                """);
        }

        // Batch-question list (always render — single-question instance is a single-entry list)
        if (summary.BatchQuestions.Count > 0)
        {
            sb.Append("""
                <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 13px; font-weight: 700; color: #B87820; margin: 16px 0 8px; text-transform: uppercase; letter-spacing: 0.5px;">Questions in this batch</p>
                <ul style="margin: 0 0 16px; padding-left: 20px;">
                """);
            foreach (var q in summary.BatchQuestions)
            {
                sb.Append("""<li style="font-family: Inter, Arial, sans-serif; font-size: 14px; color: #1A1B2E; margin: 4px 0;">""");
                if (q.IsAnswered) sb.Append("&#10003; ");
                sb.Append($"""<strong>{Encode(q.Title)}</strong> <span style="display: inline-block; padding: 1px 6px; background-color: #F5F4F0; border: 1px solid #E2E2EA; border-radius: 3px; font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 10px; font-weight: 600; color: #666677; text-transform: uppercase; letter-spacing: 0.5px;">{Encode(q.Type)}</span>""");
                if (q.IsAnswered && !string.IsNullOrWhiteSpace(q.AnsweredSummary))
                {
                    sb.Append($""" &mdash; <span style="color: #666677;">{Encode(q.AnsweredSummary)}</span>""");
                }
                sb.Append("</li>");
            }
            sb.Append("</ul>");
        }

        // Attachments — table with name + size, no links.
        if (summary.Attachments.Count > 0)
        {
            sb.Append("""
                <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 13px; font-weight: 700; color: #B87820; margin: 16px 0 8px; text-transform: uppercase; letter-spacing: 0.5px;">Attachments</p>
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse: collapse; margin: 0 0 16px;">
                """);
            foreach (var a in summary.Attachments)
            {
                sb.Append($"""
                    <tr>
                    <td style="padding: 8px 12px; border: 1px solid #E2E2EA; font-family: Inter, Arial, sans-serif; font-size: 13px; color: #1A1B2E; vertical-align: top;">{Encode(a.Name)}</td>
                    <td style="padding: 8px 12px; border: 1px solid #E2E2EA; font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 12px; color: #666677; text-align: right; width: 100px; vertical-align: top;">{Encode(DeliveryFormatting.FormatBytes(a.SizeBytes))}</td>
                    </tr>
                    """);
            }
            sb.Append("</table>");
        }

        // Review links — external URLs are safe to link directly per PRD §4.5.
        if (summary.ReviewLinks.Count > 0)
        {
            sb.Append("""
                <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 13px; font-weight: 700; color: #B87820; margin: 16px 0 8px; text-transform: uppercase; letter-spacing: 0.5px;">Review links</p>
                <ul style="margin: 0 0 16px; padding-left: 20px;">
                """);
            foreach (var r in summary.ReviewLinks)
            {
                sb.Append($"""
                    <li style="font-family: Inter, Arial, sans-serif; font-size: 14px; color: #1A1B2E; margin: 4px 0;"><a href="{Encode(r.Url)}" style="color: #B87820; text-decoration: underline;">{Encode(r.Title)}</a>
                    """);
                if (string.Equals(r.Type, "review", StringComparison.OrdinalIgnoreCase))
                {
                    sb.Append(""" <span style="color: #666677; font-size: 13px;">&mdash; requires review</span>""");
                }
                sb.Append("</li>");
            }
            sb.Append("</ul>");
        }

        // Due by — only when set.
        if (summary.DueBy.HasValue)
        {
            var dueText = DeliveryFormatting.FormatUtc(summary.DueBy.Value);
            sb.Append($"""
                <p style="font-family: Inter, Arial, sans-serif; font-size: 13px; color: #666677; margin: 16px 0 8px;"><strong style="color: #1A1B2E;">Due by:</strong> {Encode(dueText)}</p>
                """);
        }

        // Spacer before CTA
        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
            <tr><td style="height:28px; line-height:28px; font-size:1px;">&nbsp;</td></tr>
            </table>
            """);

        // CTA — same VML+HTML as legacy, fed from Summary.RespondUrl.
        if (!string.IsNullOrEmpty(summary.RespondUrl))
        {
            var encodedUrl = Encode(summary.RespondUrl);
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td align="center">
                """);
            sb.Append($"""
                <!--[if mso]>
                <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{encodedUrl}" style="height:48px;v-text-anchor:middle;width:220px;" arcsize="10%" strokecolor="#E8A030" fillcolor="#E8A030">
                <w:anchorlock/>
                <center style="font-family:Inter,Arial,sans-serif;font-size:16px;font-weight:700;color:#1A1B2E;">Respond Now</center>
                </v:roundrect>
                <![endif]-->
                <!--[if !mso]><!-->
                <a href="{encodedUrl}" style="display: inline-block; padding: 14px 48px; background-color: #E8A030; color: #1A1B2E; text-decoration: none; border-radius: 6px; font-family: Inter, Arial, sans-serif; font-size: 16px; font-weight: 700; line-height: 20px; text-align: center; mso-hide: all;">Respond Now</a>
                <!--<![endif]-->
                """);
            sb.Append("</td></tr></table>");
            sb.Append("""
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr><td style="height:28px; line-height:28px; font-size:1px;">&nbsp;</td></tr>
                </table>
                """);
        }

        // Footer
        sb.Append("""
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
            <tr><td style="border-top: 1px solid #E2E2EA; padding-top: 20px;">
            <p style="font-family: 'JetBrains Mono', 'Courier New', monospace; font-size: 12px; color: #666677; margin: 0; text-align: center;">Dotbot Question System</p>
            </td></tr></table>
            """);

        sb.Append("""
            </td></tr></table>
            <!--[if mso]>
            </td></tr></table>
            <![endif]-->
            </td></tr></table>
            </body>
            </html>
            """);

        return sb.ToString();
    }

    private static string ExtractFirstName(string? displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName))
            return "there";

        var name = displayName.Trim();

        // Handle "Last, First" enterprise AAD format
        if (name.Contains(','))
        {
            var parts = name.Split(',', 2);
            var afterComma = parts[1].Trim();
            return string.IsNullOrEmpty(afterComma) ? name : afterComma.Split(' ')[0];
        }

        // Handle "First Last" or single name
        return name.Split(' ')[0];
    }

    private static string Encode(string value) => System.Net.WebUtility.HtmlEncode(value);
}
