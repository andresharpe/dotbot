using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Builder.State;
using Microsoft.Agents.Core.Models;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server;

public class DotbotAgent : AgentApplication
{
    private readonly AdaptiveCardService _cardService;
    private readonly ResponseStorageService _responseStorage;
    private readonly IConversationReferenceStore _convoStore;
    private readonly UserResolverService _userResolver;
    private readonly ILogger<DotbotAgent> _logger;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private static readonly JsonSerializerOptions CamelOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    /// <summary>
    /// Tracks the most recent pending question per user (keyed by AAD object ID).
    /// Used to resolve plain-text replies like "A" or "B" to the correct question.
    /// </summary>
    private static readonly ConcurrentDictionary<string, PendingQuestion> PendingQuestions = new();

    public DotbotAgent(
        AgentApplicationOptions options,
        AdaptiveCardService cardService,
        ResponseStorageService responseStorage,
        IConversationReferenceStore convoStore,
        UserResolverService userResolver,
        ILogger<DotbotAgent> logger)
        : base(options)
    {
        _cardService = cardService;
        _responseStorage = responseStorage;
        _convoStore = convoStore;
        _userResolver = userResolver;
        _logger = logger;

        OnConversationUpdate(ConversationUpdateEvents.MembersAdded, OnMembersAddedAsync);
        OnActivity(ActivityTypes.Message, OnMessageAsync, rank: RouteRank.Last);
    }

    private async Task OnMembersAddedAsync(
        ITurnContext turnContext, ITurnState turnState, CancellationToken ct)
    {
        foreach (var member in turnContext.Activity.MembersAdded ?? [])
        {
            if (member.Id == turnContext.Activity.Recipient?.Id)
                continue;

            var reference = turnContext.Activity.GetConversationReference();
            var userObjectId = member.AadObjectId ?? member.Id;
            _convoStore.AddOrUpdate(userObjectId, reference);

            _logger.LogInformation("Stored conversation reference for user {UserId}", userObjectId);

            var introCard = _cardService.CreateIntroCard();
            var introAttachment = new Attachment
            {
                ContentType = "application/vnd.microsoft.card.adaptive",
                Content = JsonSerializer.Deserialize<JsonElement>(introCard.ToJson())
            };
            await turnContext.SendActivityAsync(
                MessageFactory.Attachment(introAttachment), ct);
        }
    }

    private async Task OnMessageAsync(
        ITurnContext turnContext, ITurnState turnState, CancellationToken ct)
    {
        StoreConversationReference(turnContext);

        // Card button click
        if (turnContext.Activity.Value is not null)
        {
            await HandleCardSubmitAsync(turnContext, ct);
            return;
        }

        // Plain text reply
        var text = turnContext.Activity.Text?.Trim();
        if (!string.IsNullOrEmpty(text))
        {
            var userId = turnContext.Activity.From?.AadObjectId
                       ?? turnContext.Activity.From?.Id ?? "";

            if (PendingQuestions.TryGetValue(userId, out var pending))
            {
                await HandleTextReplyAsync(turnContext, pending, text, ct);
                return;
            }
        }

        await turnContext.SendActivityAsync(
            MessageFactory.Text("No pending question. I'll send one when needed."), ct);
    }

    private async Task HandleTextReplyAsync(
        ITurnContext turnContext, PendingQuestion pending, string text, CancellationToken ct)
    {
        var userId = turnContext.Activity.From?.AadObjectId
                   ?? turnContext.Activity.From?.Id ?? "unknown";

        // Try to match option key (A, B, C...) or "a.", "A.", etc.
        var normalised = text.TrimEnd('.').ToUpperInvariant();
        var matchedOption = pending.Options.FirstOrDefault(o =>
            o.Key.Equals(normalised, StringComparison.OrdinalIgnoreCase));

        string answerText;
        string? answerKey;

        if (matchedOption is not null)
        {
            answerText = $"{matchedOption.Key} - {matchedOption.Label}";
            answerKey = matchedOption.Key;
        }
        else if (pending.AllowFreeText)
        {
            answerText = text;
            answerKey = null;
        }
        else
        {
            var validKeys = string.Join(", ", pending.Options.Select(o => o.Key));
            await turnContext.SendActivityAsync(
                MessageFactory.Text($"Please reply with one of: {validKeys}"), ct);
            return;
        }

        // Build confirmation data from PendingQuestion
        var confirmData = new CardConfirmationData
        {
            QuestionId = pending.QuestionId.ToString(),
            Question = pending.Question,
            AnswerKey = answerKey,
            AnswerLabel = answerText,
            InstanceId = pending.InstanceId.ToString(),
            ProjectId = pending.ProjectId,
            QuestionVersion = pending.QuestionVersion,
            ProjectName = pending.ProjectName,
            ProjectDescription = pending.ProjectDescription,
            Context = pending.Context,
            AllowFreeText = pending.AllowFreeText,
            OptionsJson = JsonSerializer.Serialize(pending.Options, CamelOptions),
            MagicLinkUrl = pending.MagicLinkUrl
        };

        var confirmCard = _cardService.CreatePendingConfirmationCard(
            pending.Question, answerText, confirmData);
        var attachment = new Attachment
        {
            ContentType = "application/vnd.microsoft.card.adaptive",
            Content = JsonSerializer.Deserialize<JsonElement>(confirmCard.ToJson())
        };

        // Replace the question card in-place if we have its activity ID
        if (!string.IsNullOrEmpty(pending.CardActivityId))
        {
            var updateActivity = MessageFactory.Attachment(attachment);
            updateActivity.Id = pending.CardActivityId;
            await turnContext.UpdateActivityAsync(updateActivity, ct);
        }
        else
        {
            await turnContext.SendActivityAsync(MessageFactory.Attachment(attachment), ct);
        }
    }

    private async Task HandleCardSubmitAsync(ITurnContext turnContext, CancellationToken ct)
    {
        try
        {
            var valueJson = JsonSerializer.Serialize(turnContext.Activity.Value);
            var data = JsonSerializer.Deserialize<CardSubmitData>(valueJson, JsonOptions);

            switch (data?.ActionType)
            {
                case "submitAnswer":
                    await HandleSubmitAnswerAsync(turnContext, data, ct);
                    break;
                case "confirmAnswer":
                    await HandleConfirmAnswerAsync(turnContext, data, ct);
                    break;
                case "changeAnswer":
                    await HandleChangeAnswerAsync(turnContext, data, ct);
                    break;
                default:
                    await turnContext.SendActivityAsync(
                        MessageFactory.Text("I didn't understand that response."), ct);
                    break;
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error handling card submit");
            await turnContext.SendActivityAsync(
                MessageFactory.Text("Sorry, something went wrong processing your answer."), ct);
        }
    }

    /// <summary>
    /// User clicked an option button on the question card.
    /// Don't save yet — show a pending confirmation card with Submit/Change.
    /// </summary>
    private async Task HandleSubmitAnswerAsync(
        ITurnContext turnContext, CardSubmitData data, CancellationToken ct)
    {
        if (data.QuestionId is null || data.AnswerKey is null)
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Text("I didn't understand that response."), ct);
            return;
        }

        var userId = turnContext.Activity.From?.AadObjectId
                   ?? turnContext.Activity.From?.Id ?? "unknown";

        // Resolve label from PendingQuestions if available (do NOT remove)
        PendingQuestions.TryGetValue(userId, out var pending);
        var matchedOption = pending?.Options.FirstOrDefault(o =>
            o.Key.Equals(data.AnswerKey, StringComparison.OrdinalIgnoreCase));

        // Fall back to deserializing options from card action data
        if (matchedOption is null && !string.IsNullOrEmpty(data.OptionsJson))
        {
            var opts = JsonSerializer.Deserialize<List<QuestionOption>>(data.OptionsJson, CamelOptions);
            matchedOption = opts?.FirstOrDefault(o =>
                o.Key.Equals(data.AnswerKey, StringComparison.OrdinalIgnoreCase));
        }

        var answerText = matchedOption is not null
            ? $"{matchedOption.Key} - {matchedOption.Label}"
            : data.AnswerKey;

        var confirmData = new CardConfirmationData
        {
            QuestionId = data.QuestionId,
            Question = data.Question,
            AnswerKey = data.AnswerKey,
            AnswerLabel = answerText,
            InstanceId = data.InstanceId,
            ProjectId = data.ProjectId ?? pending?.ProjectId,
            QuestionVersion = data.QuestionVersion ?? pending?.QuestionVersion ?? 1,
            ProjectName = data.ProjectName ?? pending?.ProjectName,
            ProjectDescription = data.ProjectDescription ?? pending?.ProjectDescription,
            Context = data.Context ?? pending?.Context,
            AllowFreeText = data.AllowFreeText ?? pending?.AllowFreeText ?? false,
            OptionsJson = data.OptionsJson ?? (pending != null
                ? JsonSerializer.Serialize(pending.Options, CamelOptions) : null),
            MagicLinkUrl = data.MagicLinkUrl ?? pending?.MagicLinkUrl
        };

        var confirmCard = _cardService.CreatePendingConfirmationCard(
            data.Question ?? "", answerText, confirmData);
        var attachment = new Attachment
        {
            ContentType = "application/vnd.microsoft.card.adaptive",
            Content = JsonSerializer.Deserialize<JsonElement>(confirmCard.ToJson())
        };

        // Replace the question card in-place
        var replyToId = turnContext.Activity.ReplyToId;
        if (!string.IsNullOrEmpty(replyToId))
        {
            var updateActivity = MessageFactory.Attachment(attachment);
            updateActivity.Id = replyToId;
            await turnContext.UpdateActivityAsync(updateActivity, ct);
        }
        else
        {
            await turnContext.SendActivityAsync(MessageFactory.Attachment(attachment), ct);
        }
    }

    /// <summary>
    /// User clicked "Submit" on the pending confirmation card.
    /// Save the response and replace with a locked final confirmation card.
    /// </summary>
    private async Task HandleConfirmAnswerAsync(
        ITurnContext turnContext, CardSubmitData data, CancellationToken ct)
    {
        if (data.QuestionId is null || data.AnswerKey is null)
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Text("I didn't understand that response."), ct);
            return;
        }

        var userId = turnContext.Activity.From?.AadObjectId
                   ?? turnContext.Activity.From?.Id ?? "unknown";

        // NOW we remove the pending question
        PendingQuestions.TryRemove(userId, out _);

        var answerText = data.AnswerLabel ?? data.AnswerKey;

        // Resolve option details from embedded card data
        QuestionOption? matchedOption = null;
        if (!string.IsNullOrEmpty(data.OptionsJson))
        {
            var opts = JsonSerializer.Deserialize<List<QuestionOption>>(data.OptionsJson, CamelOptions);
            matchedOption = opts?.FirstOrDefault(o =>
                o.Key.Equals(data.AnswerKey, StringComparison.OrdinalIgnoreCase));
        }

        // Resolve responder email (non-critical)
        string? responderEmail = null;
        try { responderEmail = await _userResolver.ResolveEmailAsync(userId); }
        catch (Exception ex) { _logger.LogWarning(ex, "Could not resolve email for {UserId}", userId); }

        // Deterministic ResponseId from (instanceId, questionId, userId) to prevent duplicates
        var responseId = GenerateDeterministicGuid(
            data.InstanceId ?? "", data.QuestionId, userId);

        var answer = new ResponseRecordV2
        {
            ResponseId = responseId,
            InstanceId = Guid.TryParse(data.InstanceId, out var inst) ? inst : Guid.Empty,
            QuestionId = Guid.Parse(data.QuestionId),
            QuestionVersion = data.QuestionVersion ?? 1,
            ProjectId = data.ProjectId ?? "unknown",
            SelectedKey = data.AnswerKey,
            SelectedOptionTitle = matchedOption?.Label,
            SelectedOptionId = matchedOption?.OptionId,
            FreeText = null,
            ResponderAadObjectId = userId,
            ResponderEmail = responderEmail
        };

        await _responseStorage.SaveResponseAsync(answer);
        _logger.LogInformation("Answer saved for question {QuestionId}: {Answer}",
            data.QuestionId, answerText);

        var confirmCard = _cardService.CreateFinalConfirmationCard(
            data.Question ?? "", answerText);
        var attachment = new Attachment
        {
            ContentType = "application/vnd.microsoft.card.adaptive",
            Content = JsonSerializer.Deserialize<JsonElement>(confirmCard.ToJson())
        };

        // Replace the confirmation card with the locked final card
        var replyToId = turnContext.Activity.ReplyToId;
        if (!string.IsNullOrEmpty(replyToId))
        {
            var updateActivity = MessageFactory.Attachment(attachment);
            updateActivity.Id = replyToId;
            await turnContext.UpdateActivityAsync(updateActivity, ct);
        }
        else
        {
            await turnContext.SendActivityAsync(MessageFactory.Attachment(attachment), ct);
        }
    }

    /// <summary>
    /// User clicked "Change" on the pending confirmation card.
    /// Rebuild and restore the original question card.
    /// </summary>
    private async Task HandleChangeAnswerAsync(
        ITurnContext turnContext, CardSubmitData data, CancellationToken ct)
    {
        List<QuestionOption>? options = null;
        if (!string.IsNullOrEmpty(data.OptionsJson))
        {
            options = JsonSerializer.Deserialize<List<QuestionOption>>(data.OptionsJson, CamelOptions);
        }

        if (options is null || options.Count == 0 || data.QuestionId is null)
        {
            await turnContext.SendActivityAsync(
                MessageFactory.Text("Unable to restore the question. Please wait for a new question to arrive."), ct);
            return;
        }

        var card = _cardService.CreateQuestionCard(
            data.QuestionId,
            data.Question ?? "",
            options,
            context: data.Context,
            allowFreeText: data.AllowFreeText ?? false,
            projectName: data.ProjectName,
            projectDescription: data.ProjectDescription,
            instanceId: data.InstanceId,
            magicLinkUrl: data.MagicLinkUrl,
            projectId: data.ProjectId,
            questionVersion: data.QuestionVersion ?? 1);

        var attachment = new Attachment
        {
            ContentType = "application/vnd.microsoft.card.adaptive",
            Content = JsonSerializer.Deserialize<JsonElement>(card.ToJson())
        };

        var replyToId = turnContext.Activity.ReplyToId;
        if (!string.IsNullOrEmpty(replyToId))
        {
            var updateActivity = MessageFactory.Attachment(attachment);
            updateActivity.Id = replyToId;
            await turnContext.UpdateActivityAsync(updateActivity, ct);
        }
        else
        {
            await turnContext.SendActivityAsync(MessageFactory.Attachment(attachment), ct);
        }
    }

    private void StoreConversationReference(ITurnContext turnContext)
    {
        var userObjectId = turnContext.Activity.From?.AadObjectId
                         ?? turnContext.Activity.From?.Id;
        if (userObjectId is not null)
        {
            var reference = turnContext.Activity.GetConversationReference();
            _convoStore.AddOrUpdate(userObjectId, reference);
        }
    }

    /// <summary>
    /// Registers a pending question for a user so plain-text replies can be matched.
    /// Called from the delivery provider after sending the card.
    /// </summary>
    public static void SetPendingQuestion(string userObjectId, PendingQuestion question)
    {
        PendingQuestions.AddOrUpdate(userObjectId, question, (_, _) => question);
    }

    /// <summary>
    /// Generates a deterministic GUID from composite key parts using SHA-256.
    /// Ensures the same (instanceId, questionId, userId) always produces the same ResponseId.
    /// </summary>
    private static Guid GenerateDeterministicGuid(params string[] parts)
    {
        var input = string.Join("|", parts);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        // Take first 16 bytes of SHA-256 to form a GUID
        var guidBytes = new byte[16];
        Array.Copy(hash, guidBytes, 16);
        return new Guid(guidBytes);
    }

    private class CardSubmitData
    {
        public string? ActionType { get; set; }
        public string? QuestionId { get; set; }
        public string? Question { get; set; }
        public string? AnswerKey { get; set; }
        public string? AnswerLabel { get; set; }
        public string? InstanceId { get; set; }
        public string? ProjectId { get; set; }
        public int? QuestionVersion { get; set; }
        public string? ProjectName { get; set; }
        public string? ProjectDescription { get; set; }
        public string? Context { get; set; }
        public bool? AllowFreeText { get; set; }
        public string? OptionsJson { get; set; }
        public string? MagicLinkUrl { get; set; }
    }
}

/// <summary>
/// Represents a question that has been sent to a user and is awaiting a reply.
/// </summary>
public class PendingQuestion
{
    public required Guid InstanceId { get; set; }
    public required Guid QuestionId { get; set; }
    public required string Question { get; set; }
    public required List<QuestionOption> Options { get; set; }
    public bool AllowFreeText { get; set; }
    public string? ProjectId { get; set; }
    public int QuestionVersion { get; set; } = 1;
    public string? CardActivityId { get; set; }
    public string? ProjectName { get; set; }
    public string? ProjectDescription { get; set; }
    public string? Context { get; set; }
    public string? MagicLinkUrl { get; set; }
}
