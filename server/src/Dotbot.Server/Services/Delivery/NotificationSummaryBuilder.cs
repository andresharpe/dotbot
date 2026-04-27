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
        return new NotificationSummary
        {
            QuestionTitle = template.Title,
            QuestionType = template.Type,
            ProjectName = template.Project.Name ?? template.Project.ProjectId,
            DeliverableSummary = template.DeliverableSummary ?? template.Description,
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
                    ContentType = a.MediaType ?? "application/octet-stream",
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
            DueBy = template.DeliveryDefaults?.EscalateAfterDays is int days
                ? instance.CreatedAt.AddDays(days)
                : null,
            IsReminder = isReminder,
        };
    }
}
