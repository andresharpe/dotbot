using Dotbot.Server.Models;

namespace Dotbot.Server.Services.Delivery;

public class NotificationSummaryBuilder
{
    public NotificationSummary Build(
        QuestionTemplate template,
        QuestionInstance instance,
        string respondUrl,
        bool isReminder)
    {
        ArgumentNullException.ThrowIfNull(template);
        ArgumentNullException.ThrowIfNull(instance);
        ArgumentNullException.ThrowIfNull(respondUrl);

        if (instance.QuestionId != template.QuestionId)
        {
            throw new ArgumentException(
                $"Instance QuestionId {instance.QuestionId} does not match template QuestionId {template.QuestionId}.",
                nameof(instance));
        }

        return new NotificationSummary
        {
            QuestionTitle = template.Title,
            QuestionType = template.Type,
            ProjectName = string.IsNullOrWhiteSpace(template.Project.Name)
                ? template.Project.ProjectId
                : template.Project.Name,
            // Legacy singleChoice templates carry no DeliverableSummary; providers render
            // Title + Context as before. Validator enforces non-empty for approval /
            // documentReview, so this stays null only when intentional (PRD §8 line 651).
            DeliverableSummary = template.DeliverableSummary,
            Context = template.Context,
            BatchQuestions = new List<BatchQuestionRef>
            {
                new()
                {
                    QuestionId = template.QuestionId,
                    Title = template.Title,
                    Type = template.Type,
                    // IsAnswered / AnsweredSummary populated when multi-question batches land (#289).
                }
            },
            Attachments = template.Attachments?
                .Select(a => new AttachmentRef
                {
                    Name = a.Name,
                    ContentType = string.IsNullOrWhiteSpace(a.MediaType)
                        ? "application/octet-stream"
                        : a.MediaType.Trim(),
                    SizeBytes = a.SizeBytes,
                })
                .ToList() ?? new List<AttachmentRef>(),
            ReviewLinks = template.ReferenceLinks?
                .Select(r => new ReviewLinkRef
                {
                    Title = r.Label,
                    Url = r.Url,
                })
                .ToList() ?? new List<ReviewLinkRef>(),
            RespondUrl = respondUrl,
            // DueBy is per-recipient: PRD §4.5 line 642 derives it from InstanceRecipient.SentAt,
            // not instance.CreatedAt. Set by DeliveryOrchestrator in PR-6/#287 alongside
            // RespondUrl personalisation.
            DueBy = null,
            IsReminder = isReminder,
        };
    }
}
