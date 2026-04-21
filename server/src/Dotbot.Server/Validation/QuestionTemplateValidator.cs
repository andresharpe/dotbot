using Dotbot.Server.Models;

namespace Dotbot.Server.Validation;

public static class QuestionTemplateValidator
{
    private delegate IEnumerable<string> Rule(QuestionTemplate template);

    private static readonly Rule[] Rules =
    [
        CheckQuestionId,
        CheckProjectId,
        CheckType,
        CheckDeliverableSummary,
        CheckAttachments,
    ];

    public static IReadOnlyList<string> Validate(QuestionTemplate template) =>
        Rules.SelectMany(rule => rule(template)).ToList();

    private static IEnumerable<string> CheckQuestionId(QuestionTemplate t)
    {
        if (t.QuestionId == Guid.Empty)
            yield return "questionId must be a GUID";
    }

    private static IEnumerable<string> CheckProjectId(QuestionTemplate t)
    {
        if (string.IsNullOrWhiteSpace(t.Project.ProjectId))
            yield return "project.projectId is required";
    }

    private static IEnumerable<string> CheckType(QuestionTemplate t)
    {
        if (Array.IndexOf(QuestionTypes.AllowedTypes, t.Type) < 0)
            yield return $"Unknown type '{t.Type}'. Allowed types: {string.Join(", ", QuestionTypes.AllowedTypes)}";
    }

    private static IEnumerable<string> CheckDeliverableSummary(QuestionTemplate t)
    {
        if ((t.Type == QuestionTypes.Approval || t.Type == QuestionTypes.DocumentReview)
            && string.IsNullOrWhiteSpace(t.DeliverableSummary))
            yield return $"deliverableSummary is required when type is '{t.Type}'";
    }

    private static IEnumerable<string> CheckAttachments(QuestionTemplate t)
    {
        if (t.Attachments is null) yield break;
        for (var i = 0; i < t.Attachments.Count; i++)
        {
            var a = t.Attachments[i];
            var hasUrl = !string.IsNullOrWhiteSpace(a.Url);
            var hasBlobPath = !string.IsNullOrWhiteSpace(a.BlobPath);
            if (hasUrl == hasBlobPath)
                yield return $"attachments[{i}] must have exactly one of 'url' or 'blobPath'";
        }
    }
}
