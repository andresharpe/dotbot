using Dotbot.Server.Models;
using System.Text.RegularExpressions;

namespace Dotbot.Server.Validation;

/// <summary>
/// Boundary validation for <see cref="CreateInstanceRequest"/>. Mirrors the shape of
/// <see cref="QuestionTemplateValidator"/>: a list of pure rules emitting human-readable
/// strings, no exceptions. Wired into <c>POST /api/instances</c>.
///
/// Runtime / side-effectful checks stay in the endpoint:
///   - JSON parse success (before the validator runs)
///   - <c>InstanceId</c> default-fill (mutation, not validation)
///   - Channel availability (depends on registered <c>IQuestionDeliveryProvider</c> set)
///   - Template existence (async storage lookup)
/// </summary>
public class QuestionInstanceValidator
{
    // Same lenient email shape the endpoint used before this validator existed.
    // Kept here as the canonical regex so future producers (push-back, dual-surface)
    // can share it via the validator instead of re-implementing.
    private static readonly Regex EmailPattern = new(
        @"^[^@\s]+@[^@\s]+\.[^@\s]+$",
        RegexOptions.Compiled);

    private delegate IEnumerable<string> Rule(CreateInstanceRequest request);

    private readonly Rule[] _rules;

    public QuestionInstanceValidator()
    {
        _rules =
        [
            CheckQuestionId,
            CheckJiraIssueKey,
            CheckRecipientsPresent,
            CheckRecipientEmails,
            CheckDeliveryOverrides,
        ];
    }

    public IReadOnlyList<string> Validate(CreateInstanceRequest request) =>
        _rules.SelectMany(rule => rule(request)).ToList();

    private IEnumerable<string> CheckQuestionId(CreateInstanceRequest r)
    {
        if (r.QuestionId == Guid.Empty)
            yield return "questionId must be a GUID";
    }

    private IEnumerable<string> CheckJiraIssueKey(CreateInstanceRequest r)
    {
        if (r.Channel == "jira" && string.IsNullOrEmpty(r.JiraIssueKey))
            yield return "jiraIssueKey is required when channel is 'jira'";
    }

    private IEnumerable<string> CheckRecipientsPresent(CreateInstanceRequest r)
    {
        var emails = r.Recipients?.Emails?.Count ?? 0;
        var objectIds = r.Recipients?.UserObjectIds?.Count ?? 0;
        var slackUserIds = r.Recipients?.SlackUserIds?.Count ?? 0;
        if (emails == 0 && objectIds == 0 && slackUserIds == 0)
            yield return "At least one email, userObjectId, or slackUserId is required in recipients";
    }

    private IEnumerable<string> CheckRecipientEmails(CreateInstanceRequest r)
    {
        var emails = r.Recipients?.Emails;
        if (emails is null || emails.Count == 0) yield break;

        var invalid = emails
            .Where(e => string.IsNullOrWhiteSpace(e) || !EmailPattern.IsMatch(e))
            .ToList();
        if (invalid.Count > 0)
            yield return $"Invalid email address(es): {string.Join(", ", invalid)}";
    }

    private IEnumerable<string> CheckDeliveryOverrides(CreateInstanceRequest r)
    {
        if (r.DeliveryOverrides is null) yield break;

        // Range bounds match DeliveryDefaults in QuestionTemplateValidator. Centralised
        // upper bounds live on DeliveryDefaults so both validators reference the same
        // numeric value without sharing validator code.
        if (r.DeliveryOverrides.ReminderAfterHours is { } rah && (rah < 1 || rah > DeliveryDefaults.MaxReminderAfterHours))
            yield return $"deliveryOverrides.reminderAfterHours must be between 1 and {DeliveryDefaults.MaxReminderAfterHours} (got {rah})";

        if (r.DeliveryOverrides.EscalateAfterDays is { } ead && (ead < 1 || ead > DeliveryDefaults.MaxEscalateAfterDays))
            yield return $"deliveryOverrides.escalateAfterDays must be between 1 and {DeliveryDefaults.MaxEscalateAfterDays} (got {ead})";
    }
}
