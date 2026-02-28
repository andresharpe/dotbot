using AdaptiveCards;
using Dotbot.Server.Models;
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
