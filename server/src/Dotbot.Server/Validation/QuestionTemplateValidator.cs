using Dotbot.Server.Models;
using Microsoft.Extensions.Options;

namespace Dotbot.Server.Validation;

public class QuestionTemplateValidator
{
    private delegate IEnumerable<string> Rule(QuestionTemplate template);

    private readonly QuestionTemplateValidationSettings _settings;
    private readonly Rule[] _rules;

    public QuestionTemplateValidator(IOptions<QuestionTemplateValidationSettings> settings)
    {
        _settings = settings.Value;
        _rules =
        [
            CheckQuestionId,
            CheckProjectId,
            CheckType,
            CheckDeliverableSummary,
            CheckAttachments,
            CheckReferenceLinks,
        ];
    }

    public IReadOnlyList<string> Validate(QuestionTemplate template) =>
        _rules.SelectMany(rule => rule(template)).ToList();

    private IEnumerable<string> CheckQuestionId(QuestionTemplate t)
    {
        if (t.QuestionId == Guid.Empty)
            yield return "questionId must be a GUID";
    }

    private IEnumerable<string> CheckProjectId(QuestionTemplate t)
    {
        if (t.Project is null || string.IsNullOrWhiteSpace(t.Project.ProjectId))
            yield return "project.projectId is required";
    }

    private IEnumerable<string> CheckType(QuestionTemplate t)
    {
        if (Array.IndexOf(QuestionTypes.AllowedTypes, t.Type) < 0)
            yield return $"Unknown type '{t.Type}'. Allowed types: {string.Join(", ", QuestionTypes.AllowedTypes)}";
    }

    private IEnumerable<string> CheckDeliverableSummary(QuestionTemplate t)
    {
        if ((t.Type == QuestionTypes.Approval || t.Type == QuestionTypes.DocumentReview)
            && string.IsNullOrWhiteSpace(t.DeliverableSummary))
            yield return $"deliverableSummary is required when type is '{t.Type}'";
    }

    private IEnumerable<string> CheckAttachments(QuestionTemplate t)
    {
        if (t.Attachments is null) yield break;
        if (t.Attachments.Count > _settings.MaxAttachments)
        {
            yield return $"attachments must contain at most {_settings.MaxAttachments} entries (got {t.Attachments.Count})";
            yield break;
        }
        for (var i = 0; i < t.Attachments.Count; i++)
        {
            var a = t.Attachments[i];
            var hasUrl = !string.IsNullOrWhiteSpace(a.Url);
            var hasBlobPath = !string.IsNullOrWhiteSpace(a.BlobPath);
            if (hasUrl == hasBlobPath)
            {
                yield return $"attachments[{i}] must have exactly one of 'url' or 'blobPath'";
                continue;
            }
            if (hasUrl && !IsSafeHttpsUrl(a.Url!))
                yield return $"attachments[{i}].url must be an absolute https:// URL";
            if (hasBlobPath && !IsSafeBlobPath(a.BlobPath!))
                yield return $"attachments[{i}].blobPath must be a relative path with no '..' segments";
        }
    }

    private IEnumerable<string> CheckReferenceLinks(QuestionTemplate t)
    {
        if (t.ReferenceLinks is null) yield break;
        if (t.ReferenceLinks.Count > _settings.MaxReferenceLinks)
        {
            yield return $"referenceLinks must contain at most {_settings.MaxReferenceLinks} entries (got {t.ReferenceLinks.Count})";
            yield break;
        }
        for (var i = 0; i < t.ReferenceLinks.Count; i++)
        {
            if (!IsSafeHttpsUrl(t.ReferenceLinks[i].Url))
                yield return $"referenceLinks[{i}].url must be an absolute https:// URL";
        }
    }

    private static bool IsSafeHttpsUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps;

    private static bool IsSafeBlobPath(string p)
    {
        if (string.IsNullOrEmpty(p)) return false;
        if (p.StartsWith('/') || p.StartsWith('\\') || p.Contains('\\')) return false;
        foreach (var seg in p.Split('/'))
            if (seg is ".." or "." || string.IsNullOrWhiteSpace(seg)) return false;
        return true;
    }
}
