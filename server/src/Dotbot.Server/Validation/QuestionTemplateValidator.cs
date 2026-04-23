using System.Net;
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
            CheckOptionUniqueness,
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

    private IEnumerable<string> CheckOptionUniqueness(QuestionTemplate t)
    {
        if (t.Options is null) yield break;
        foreach (var g in t.Options.GroupBy(o => o.OptionId).Where(g => g.Count() > 1))
            yield return $"options contain duplicate optionId '{g.Key}'";
        foreach (var g in t.Options.GroupBy(o => o.Key, StringComparer.Ordinal).Where(g => g.Count() > 1))
            yield return $"options contain duplicate key '{g.Key}'";
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

    private static bool IsSafeHttpsUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u)) return false;
        if (u.Scheme != Uri.UriSchemeHttps) return false;
        if (!string.IsNullOrEmpty(u.UserInfo)) return false;
        if (u.IsLoopback) return false;

        // Reject non-standard IP-literal forms that some browsers/resolvers honour but IPAddress.TryParse
        // on .NET 9 doesn't: decimal integer (e.g. 2130706433 for 127.0.0.1), hex (0x...), and trailing-dot
        // variants of hostnames. Doesn't cover dotted-octal (e.g. 0177.0.0.1) — known limitation.
        var host = u.Host.TrimEnd('.');
        if (string.IsNullOrEmpty(host)) return false;
        if (host.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) return false;
        if (host.All(char.IsDigit)) return false;

        if (IPAddress.TryParse(host, out var ip))
        {
            if (ip.IsIPv4MappedToIPv6)
                ip = ip.MapToIPv4();

            var b = ip.GetAddressBytes();
            if (b.Length == 4 && (
                b[0] == 10 ||
                b[0] == 127 ||
                (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
                (b[0] == 192 && b[1] == 168) ||
                (b[0] == 169 && b[1] == 254)))
                return false;

            if (b.Length == 16 && (b[0] & 0xFE) == 0xFC)
                return false;
        }
        else if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
              || host.EndsWith(".internal", StringComparison.OrdinalIgnoreCase)
              || host.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return true;
    }

    private static bool IsSafeBlobPath(string p)
    {
        if (string.IsNullOrEmpty(p)) return false;
        if (p.StartsWith('/') || p.StartsWith('\\') || p.Contains('\\')) return false;
        foreach (var seg in p.Split('/'))
            if (seg is ".." or "." || string.IsNullOrWhiteSpace(seg)) return false;
        return true;
    }
}
