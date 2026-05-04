using AdaptiveCards;
using Dotbot.Server.Models;
using Dotbot.Server.Services.Delivery;
using System.Text.Json;

namespace Dotbot.Server.Services;

/// <summary>
/// Builds Adaptive Cards for question prompts and confirmation responses.
/// </summary>
public class AdaptiveCardService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    /// <summary>
    /// Creates a question card with lettered options and optional rationales.
    /// Users can click a button or reply with plain text (e.g. "A" or "B").
    /// All fields needed for the confirm-to-save flow are embedded in each button's action data.
    /// </summary>
    public AdaptiveCard CreateQuestionCard(
        string questionId, string questionText, List<QuestionOption> options,
        string? context = null, bool allowFreeText = false,
        string? projectName = null, string? projectDescription = null,
        string? instanceId = null, string? magicLinkUrl = null,
        string? projectId = null, int questionVersion = 1)
    {
        var body = new List<AdaptiveElement>();

        // Project banner — emphasis container with accent heading
        if (!string.IsNullOrWhiteSpace(projectName))
        {
            var projectItems = new List<AdaptiveElement>
            {
                new AdaptiveTextBlock
                {
                    Text = projectName,
                    Wrap = true,
                    Weight = AdaptiveTextWeight.Bolder,
                    Size = AdaptiveTextSize.Medium,
                    Color = AdaptiveTextColor.Good
                }
            };

            if (!string.IsNullOrWhiteSpace(projectDescription))
            {
                projectItems.Add(new AdaptiveTextBlock
                {
                    Text = projectDescription,
                    Wrap = true,
                    IsSubtle = true,
                    Size = AdaptiveTextSize.Small,
                    Spacing = AdaptiveSpacing.None
                });
            }

            body.Add(new AdaptiveContainer
            {
                Style = AdaptiveContainerStyle.Emphasis,
                Bleed = true,
                Items = projectItems,
                Spacing = AdaptiveSpacing.None
            });
        }

        // Question text
        body.Add(new AdaptiveTextBlock
        {
            Text = questionText,
            Wrap = true,
            Weight = AdaptiveTextWeight.Bolder,
            Color = AdaptiveTextColor.Warning,
            Size = AdaptiveTextSize.Default,
            Separator = true
        });

        // Context block
        if (!string.IsNullOrWhiteSpace(context))
        {
            body.Add(new AdaptiveTextBlock
            {
                Text = context,
                Wrap = true,
                IsSubtle = true,
                Size = AdaptiveTextSize.Small,
                Spacing = AdaptiveSpacing.Small
            });
        }

        // Options — lettered with bold key
        for (var i = 0; i < options.Count; i++)
        {
            var option = options[i];
            var optionText = !string.IsNullOrWhiteSpace(option.Rationale)
                ? $"**{option.Key}.** {option.Label} \u2014 {option.Rationale}"
                : $"**{option.Key}.** {option.Label}";

            body.Add(new AdaptiveTextBlock
            {
                Text = optionText,
                Wrap = true,
                Color = AdaptiveTextColor.Warning,
                Size = AdaptiveTextSize.Default,
                Separator = i == 0,
                Spacing = i == 0 ? AdaptiveSpacing.Medium : AdaptiveSpacing.Small
            });
        }

        // Free text hint
        if (allowFreeText)
        {
            body.Add(new AdaptiveTextBlock
            {
                Text = "You can also type a free-text reply.",
                Wrap = true,
                IsSubtle = true,
                Size = AdaptiveTextSize.Small,
                Separator = true
            });
        }

        var optionsJson = JsonSerializer.Serialize(options, JsonOptions);

        // Option buttons — each carries full action data for the confirm-to-save flow
        var actions = options.Select(o => (AdaptiveAction)new AdaptiveSubmitAction
        {
            Title = o.Key,
            Data = new
            {
                actionType = "submitAnswer",
                questionId,
                question = questionText,
                answerKey = o.Key,
                instanceId,
                projectId,
                questionVersion,
                projectName,
                projectDescription,
                context,
                allowFreeText,
                optionsJson,
                magicLinkUrl
            }
        }).ToList();

        // "Open in Browser" button
        if (!string.IsNullOrEmpty(magicLinkUrl))
        {
            actions.Add(new AdaptiveOpenUrlAction
            {
                Title = "Open in Browser",
                Url = new Uri(magicLinkUrl)
            });
        }

        return new AdaptiveCard(new AdaptiveSchemaVersion(1, 5))
        {
            Body = body,
            Actions = actions
        };
    }

    /// <summary>
    /// Renders a NotificationSummary as a triage Adaptive Card with a single Respond Now action.
    /// </summary>
    public AdaptiveCard CreateSummaryCard(NotificationSummary summary)
    {
        if (!Uri.TryCreate(summary.RespondUrl, UriKind.Absolute, out var respondUri))
        {
            throw new ArgumentException(
                $"NotificationSummary.RespondUrl must be an absolute URL; got '{summary.RespondUrl}'.",
                nameof(summary));
        }

        var body = new List<AdaptiveElement>();

        // Reminder banner — sits above the project banner so re-deliveries are immediately visible
        if (summary.IsReminder)
        {
            body.Add(new AdaptiveContainer
            {
                Style = AdaptiveContainerStyle.Warning,
                Bleed = true,
                Spacing = AdaptiveSpacing.None,
                Items = new List<AdaptiveElement>
                {
                    new AdaptiveRichTextBlock
                    {
                        Inlines = new List<AdaptiveInline>
                        {
                            new AdaptiveTextRun
                            {
                                Text = "⏰ Reminder — this question is still awaiting your response.",
                                Weight = AdaptiveTextWeight.Bolder,
                                Color = AdaptiveTextColor.Warning
                            }
                        }
                    }
                }
            });
        }

        // Project banner. RichTextBlock + TextRun renders DTO strings as literal text — never
        // parsed as Markdown, so untrusted fields (project names, titles, attachment names, etc.)
        // cannot inject `[label](url)` hyperlinks or other formatting into the card.
        body.Add(new AdaptiveContainer
        {
            Style = AdaptiveContainerStyle.Emphasis,
            Bleed = true,
            Spacing = AdaptiveSpacing.None,
            Items = new List<AdaptiveElement>
            {
                new AdaptiveRichTextBlock
                {
                    Inlines = new List<AdaptiveInline>
                    {
                        new AdaptiveTextRun
                        {
                            Text = summary.ProjectName,
                            Weight = AdaptiveTextWeight.Bolder,
                            Size = AdaptiveTextSize.Medium,
                            Color = AdaptiveTextColor.Good
                        }
                    }
                }
            }
        });

        // Header: title + type badge
        body.Add(new AdaptiveRichTextBlock
        {
            Separator = true,
            Inlines = new List<AdaptiveInline>
            {
                new AdaptiveTextRun
                {
                    Text = summary.QuestionTitle,
                    Weight = AdaptiveTextWeight.Bolder,
                    Size = AdaptiveTextSize.Large,
                    Color = AdaptiveTextColor.Warning
                }
            }
        });
        body.Add(new AdaptiveRichTextBlock
        {
            Spacing = AdaptiveSpacing.None,
            Inlines = new List<AdaptiveInline>
            {
                new AdaptiveTextRun { Text = "Type: ", Size = AdaptiveTextSize.Small },
                new AdaptiveTextRun { Text = summary.QuestionType, Size = AdaptiveTextSize.Small }
            }
        });

        if (summary.DueBy.HasValue)
        {
            body.Add(new AdaptiveRichTextBlock
            {
                Spacing = AdaptiveSpacing.None,
                Inlines = new List<AdaptiveInline>
                {
                    new AdaptiveTextRun { Text = "Due by: ", Size = AdaptiveTextSize.Small, Weight = AdaptiveTextWeight.Bolder },
                    new AdaptiveTextRun { Text = DeliveryFormatting.FormatUtc(summary.DueBy.Value), Size = AdaptiveTextSize.Small }
                }
            });
        }

        if (!string.IsNullOrWhiteSpace(summary.DeliverableSummary))
        {
            body.Add(new AdaptiveRichTextBlock
            {
                Spacing = AdaptiveSpacing.Medium,
                Inlines = new List<AdaptiveInline>
                {
                    new AdaptiveTextRun { Text = summary.DeliverableSummary }
                }
            });
        }

        if (!string.IsNullOrWhiteSpace(summary.Context))
        {
            body.Add(new AdaptiveRichTextBlock
            {
                Spacing = AdaptiveSpacing.Small,
                Inlines = new List<AdaptiveInline>
                {
                    new AdaptiveTextRun { Text = summary.Context, Size = AdaptiveTextSize.Small }
                }
            });
        }

        if (summary.BatchQuestions.Count > 0)
        {
            body.Add(new AdaptiveTextBlock
            {
                Text = "Questions in this batch",
                Weight = AdaptiveTextWeight.Bolder,
                Size = AdaptiveTextSize.Small,
                Spacing = AdaptiveSpacing.Medium,
                Separator = true
            });
            foreach (var q in summary.BatchQuestions)
            {
                var inlines = new List<AdaptiveInline>
                {
                    new AdaptiveTextRun { Text = q.IsAnswered ? "✓ " : "⏳ ", Size = AdaptiveTextSize.Small },
                    new AdaptiveTextRun { Text = q.Title, Size = AdaptiveTextSize.Small },
                    new AdaptiveTextRun { Text = " (", Size = AdaptiveTextSize.Small },
                    new AdaptiveTextRun { Text = q.Type, Size = AdaptiveTextSize.Small },
                    new AdaptiveTextRun { Text = ")", Size = AdaptiveTextSize.Small }
                };
                if (!string.IsNullOrWhiteSpace(q.AnsweredSummary))
                {
                    inlines.Add(new AdaptiveTextRun { Text = " — ", Size = AdaptiveTextSize.Small });
                    inlines.Add(new AdaptiveTextRun { Text = q.AnsweredSummary, Size = AdaptiveTextSize.Small });
                }
                body.Add(new AdaptiveRichTextBlock
                {
                    Spacing = AdaptiveSpacing.None,
                    Inlines = inlines
                });
            }
        }

        if (summary.Attachments.Count > 0)
        {
            body.Add(new AdaptiveTextBlock
            {
                Text = "Attachments",
                Weight = AdaptiveTextWeight.Bolder,
                Size = AdaptiveTextSize.Small,
                Spacing = AdaptiveSpacing.Medium,
                Separator = true
            });
            foreach (var a in summary.Attachments)
            {
                body.Add(new AdaptiveRichTextBlock
                {
                    Spacing = AdaptiveSpacing.None,
                    Inlines = new List<AdaptiveInline>
                    {
                        new AdaptiveTextRun { Text = "• ", Size = AdaptiveTextSize.Small },
                        new AdaptiveTextRun { Text = a.Name, Size = AdaptiveTextSize.Small },
                        new AdaptiveTextRun { Text = $" ({DeliveryFormatting.FormatBytes(a.SizeBytes)})", Size = AdaptiveTextSize.Small }
                    }
                });
            }
        }

        if (summary.ReviewLinks.Count > 0)
        {
            body.Add(new AdaptiveTextBlock
            {
                Text = "Review links",
                Weight = AdaptiveTextWeight.Bolder,
                Size = AdaptiveTextSize.Small,
                Spacing = AdaptiveSpacing.Medium,
                Separator = true
            });
            foreach (var link in summary.ReviewLinks)
            {
                // Skip non-absolute or non-http(s) URLs — blocks scheme spoofing
                // (javascript:, data:) and matches the Slack provider's allowlist.
                if (!Uri.TryCreate(link.Url, UriKind.Absolute, out var linkUri) ||
                    (linkUri.Scheme != Uri.UriSchemeHttp && linkUri.Scheme != Uri.UriSchemeHttps))
                {
                    continue;
                }

                var inlines = new List<AdaptiveInline>
                {
                    new AdaptiveTextRun { Text = "• ", Size = AdaptiveTextSize.Small, Color = AdaptiveTextColor.Accent },
                    new AdaptiveTextRun { Text = link.Title, Size = AdaptiveTextSize.Small, Color = AdaptiveTextColor.Accent }
                };
                if (!string.IsNullOrWhiteSpace(link.Type))
                {
                    inlines.Add(new AdaptiveTextRun { Text = " (requires review)", Size = AdaptiveTextSize.Small, Color = AdaptiveTextColor.Accent });
                }

                body.Add(new AdaptiveContainer
                {
                    Spacing = AdaptiveSpacing.None,
                    SelectAction = new AdaptiveOpenUrlAction { Url = linkUri },
                    Items = new List<AdaptiveElement>
                    {
                        new AdaptiveRichTextBlock { Inlines = inlines }
                    }
                });
            }
        }

        var actions = new List<AdaptiveAction>
        {
            new AdaptiveOpenUrlAction
            {
                Title = "Respond Now",
                Url = respondUri
            }
        };

        return new AdaptiveCard(new AdaptiveSchemaVersion(1, 5))
        {
            Body = body,
            Actions = actions
        };
    }

    /// <summary>
    /// Creates a pending confirmation card shown after the user clicks an option but before saving.
    /// Has Submit (save) and Change (go back) buttons.
    /// </summary>
    public AdaptiveCard CreatePendingConfirmationCard(
        string questionText, string selectedChoice, CardConfirmationData data)
    {
        var body = new List<AdaptiveElement>
        {
            new AdaptiveTextBlock
            {
                Text = questionText,
                Wrap = true,
                IsSubtle = true
            },
            new AdaptiveTextBlock
            {
                Text = $"You selected: **{selectedChoice}**",
                Wrap = true,
                Color = AdaptiveTextColor.Warning,
                Weight = AdaptiveTextWeight.Bolder
            },
            new AdaptiveTextBlock
            {
                Text = "Submit your answer or change your selection.",
                Wrap = true,
                IsSubtle = true,
                Size = AdaptiveTextSize.Small
            }
        };

        var actions = new List<AdaptiveAction>
        {
            new AdaptiveSubmitAction
            {
                Title = "Submit",
                Style = "positive",
                Data = new
                {
                    actionType = "confirmAnswer",
                    data.QuestionId,
                    data.Question,
                    data.AnswerKey,
                    data.InstanceId,
                    data.ProjectId,
                    data.QuestionVersion,
                    data.AnswerLabel,
                    data.OptionsJson
                }
            },
            new AdaptiveSubmitAction
            {
                Title = "Change",
                Data = new
                {
                    actionType = "changeAnswer",
                    data.QuestionId,
                    data.Question,
                    data.InstanceId,
                    data.ProjectId,
                    data.QuestionVersion,
                    data.ProjectName,
                    data.ProjectDescription,
                    data.Context,
                    data.AllowFreeText,
                    data.OptionsJson,
                    data.MagicLinkUrl
                }
            }
        };

        return new AdaptiveCard(new AdaptiveSchemaVersion(1, 5))
        {
            Body = body,
            Actions = actions
        };
    }

    /// <summary>
    /// Creates an intro card shown the first time Dotbot contacts a user.
    /// </summary>
    public AdaptiveCard CreateIntroCard()
    {
        return new AdaptiveCard(new AdaptiveSchemaVersion(1, 5))
        {
            Body =
            [
                new AdaptiveContainer
                {
                    Style = AdaptiveContainerStyle.Emphasis,
                    Bleed = true,
                    Spacing = AdaptiveSpacing.None,
                    Items =
                    [
                        new AdaptiveTextBlock
                        {
                            Text = "Dotbot",
                            Wrap = true,
                            Weight = AdaptiveTextWeight.Bolder,
                            Size = AdaptiveTextSize.Medium,
                            Color = AdaptiveTextColor.Good
                        }
                    ]
                },
                new AdaptiveTextBlock
                {
                    Text = "You've been selected as an expert \u2014 your insight matters.",
                    Wrap = true,
                    Weight = AdaptiveTextWeight.Bolder,
                    Color = AdaptiveTextColor.Warning,
                    Separator = true
                },
                new AdaptiveTextBlock
                {
                    Text = "This channel will be used for business change initiatives "
                         + "across the group. I'll send you focused questions from time "
                         + "to time and responding swiftly helps keep new initiatives on track.",
                    Wrap = true,
                    Color = AdaptiveTextColor.Warning,
                    Spacing = AdaptiveSpacing.Small
                },
                new AdaptiveTextBlock
                {
                    Text = "Just pick your answer and you're done.",
                    Wrap = true,
                    IsSubtle = true,
                    Size = AdaptiveTextSize.Small,
                    Separator = true
                }
            ]
        };
    }

    /// <summary>
    /// Creates a final locked confirmation card shown after the answer is saved.
    /// No buttons — the answer is recorded and the card is locked.
    /// </summary>
    public AdaptiveCard CreateFinalConfirmationCard(string questionText, string selectedChoice)
    {
        return new AdaptiveCard(new AdaptiveSchemaVersion(1, 5))
        {
            Body =
            [
                new AdaptiveTextBlock
                {
                    Text = "\u2713 Answer recorded",
                    Weight = AdaptiveTextWeight.Bolder,
                    Size = AdaptiveTextSize.Medium,
                    Color = AdaptiveTextColor.Good
                },
                new AdaptiveTextBlock
                {
                    Text = questionText,
                    Wrap = true,
                    IsSubtle = true
                },
                new AdaptiveTextBlock
                {
                    Text = $"You selected: **{selectedChoice}**",
                    Wrap = true,
                    Color = AdaptiveTextColor.Warning
                }
            ]
        };
    }
}

/// <summary>
/// Carries all fields needed to build confirmation and change-answer cards.
/// </summary>
public class CardConfirmationData
{
    public string? QuestionId { get; set; }
    public string? Question { get; set; }
    public string? AnswerKey { get; set; }
    public string? AnswerLabel { get; set; }
    public string? InstanceId { get; set; }
    public string? ProjectId { get; set; }
    public int QuestionVersion { get; set; }
    public string? ProjectName { get; set; }
    public string? ProjectDescription { get; set; }
    public string? Context { get; set; }
    public bool AllowFreeText { get; set; }
    public string? OptionsJson { get; set; }
    public string? MagicLinkUrl { get; set; }
}
