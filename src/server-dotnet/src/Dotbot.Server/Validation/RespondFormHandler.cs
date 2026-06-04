using Dotbot.Server.Models;

namespace Dotbot.Server.Validation;

public sealed record RespondFormInput(
    string? SelectedKey = null,
    string? FreeText = null,
    string? ApprovalDecision = null,
    string? Comment = null,
    IReadOnlyList<Guid>? ReviewedAttachmentIds = null,
    IReadOnlyList<RankedItem>? RankedItems = null,
    int UploadedAttachmentCount = 0);

public sealed class RespondFormResult
{
    public bool IsValid => Error is null;
    public string? Error { get; init; }

    public string? SelectedKey { get; init; }
    public Guid? SelectedOptionId { get; init; }
    public string? SelectedOptionTitle { get; init; }
    public string? FreeText { get; init; }
    public string? ApprovalDecision { get; init; }
    public string? Comment { get; init; }
    public IReadOnlyList<Guid>? ReviewedAttachmentIds { get; init; }
    public IReadOnlyList<RankedItem>? RankedItems { get; init; }

    public string? SelectionLabel { get; init; }

    public static RespondFormResult Fail(string error) => new() { Error = error };
}

public static class RespondFormHandler
{
    public static RespondFormResult Validate(QuestionTemplate template, RespondFormInput input)
    {
        ArgumentNullException.ThrowIfNull(template);
        ArgumentNullException.ThrowIfNull(input);

        return template.Type switch
        {
            QuestionTypes.Approval => ValidateApproval(template, input),
            QuestionTypes.FreeText => ValidateFreeText(input),
            QuestionTypes.PriorityRanking => ValidatePriorityRanking(template, input),
            QuestionTypes.SingleChoice or QuestionTypes.MultiChoice
                => ValidateSingleOrMultiChoice(template, input),
            _ => RespondFormResult.Fail($"Unsupported question type '{template.Type}'."),
        };
    }

    private static RespondFormResult ValidateApproval(QuestionTemplate template, RespondFormInput input)
    {
        var decision = input.ApprovalDecision?.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(decision) || !ApprovalDecisions.ApprovalAllowed.Contains(decision))
            return RespondFormResult.Fail("Please choose Approve or Reject.");

        if (decision == ApprovalDecisions.Rejected && string.IsNullOrWhiteSpace(input.Comment))
            return RespondFormResult.Fail("A comment is required when rejecting.");

        var templateAttachments = template.Attachments ?? new List<QuestionAttachment>();
        if (templateAttachments.Count > 0)
        {
            var validIds = templateAttachments
                .Where(a => a is not null)
                .Select(a => a.AttachmentId)
                .ToHashSet();

            var reviewed = (input.ReviewedAttachmentIds ?? Array.Empty<Guid>())
                .Where(id => validIds.Contains(id))
                .Distinct()
                .ToList();

            if (reviewed.Count == 0)
                return RespondFormResult.Fail("Please confirm you reviewed at least one attachment.");

            return new RespondFormResult
            {
                ApprovalDecision = decision,
                Comment = NullIfBlank(input.Comment),
                ReviewedAttachmentIds = reviewed,
                SelectionLabel = ApprovalDecisions.Label(decision),
            };
        }

        return new RespondFormResult
        {
            ApprovalDecision = decision,
            Comment = NullIfBlank(input.Comment),
            SelectionLabel = ApprovalDecisions.Label(decision),
        };
    }

    private static RespondFormResult ValidateFreeText(RespondFormInput input)
    {
        if (string.IsNullOrWhiteSpace(input.FreeText))
            return RespondFormResult.Fail("Please type a response.");

        return new RespondFormResult
        {
            FreeText = input.FreeText.Trim(),
            SelectionLabel = "Free-text response",
        };
    }

    private static RespondFormResult ValidatePriorityRanking(QuestionTemplate template, RespondFormInput input)
    {
        var ranked = input.RankedItems?.Where(r => r is not null).ToList() ?? new List<RankedItem>();
        var optionIds = template.Options.Where(o => o is not null).Select(o => o.OptionId).ToList();

        if (optionIds.Count == 0)
            return RespondFormResult.Fail("Question has no options to rank.");

        if (ranked.Count != optionIds.Count)
            return RespondFormResult.Fail("Please rank every option exactly once.");

        var rankedIds = ranked.Select(r => r.OptionId).ToHashSet();
        if (rankedIds.Count != optionIds.Count || !optionIds.All(rankedIds.Contains))
            return RespondFormResult.Fail("Ranking must include every option exactly once.");

        var ranks = ranked.Select(r => r.Rank).OrderBy(r => r).ToList();
        for (var i = 0; i < ranks.Count; i++)
        {
            if (ranks[i] != i + 1)
                return RespondFormResult.Fail($"Ranks must be 1..{optionIds.Count} with no gaps or duplicates.");
        }

        return new RespondFormResult
        {
            RankedItems = ranked,
            SelectionLabel = $"{ranked.Count} option(s) ranked",
        };
    }

    private static RespondFormResult ValidateSingleOrMultiChoice(QuestionTemplate template, RespondFormInput input)
    {
        var selected = string.IsNullOrEmpty(input.SelectedKey)
            ? null
            : template.Options.FirstOrDefault(o => o is not null && o.Key == input.SelectedKey);

        if (!string.IsNullOrEmpty(input.SelectedKey) && selected is null)
            return RespondFormResult.Fail("Invalid selection.");

        var freeText = NullIfBlank(input.FreeText);
        var allowFreeText = template.ResponseSettings?.AllowFreeText ?? false;
        if (freeText is not null && !allowFreeText)
            return RespondFormResult.Fail("Free-text response is not allowed for this question.");

        if (selected is null && freeText is null && input.UploadedAttachmentCount == 0)
            return RespondFormResult.Fail("Please select an option, type a response, or attach a file.");

        var label = selected is not null
            ? $"{selected.Key}. {selected.Title}"
            : input.UploadedAttachmentCount > 0
                ? $"{input.UploadedAttachmentCount} file(s) attached"
                : "Custom response";

        return new RespondFormResult
        {
            SelectedKey = selected?.Key,
            SelectedOptionId = selected?.OptionId,
            SelectedOptionTitle = selected?.Title,
            FreeText = freeText,
            SelectionLabel = label,
        };
    }

    private static string? NullIfBlank(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
