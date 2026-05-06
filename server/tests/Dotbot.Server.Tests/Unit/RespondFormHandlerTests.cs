using Dotbot.Server.Models;
using Dotbot.Server.Validation;

namespace Dotbot.Server.Tests.Unit;

public class RespondFormHandlerTests
{
    private static QuestionTemplate Template(string type, params TemplateOption[] options) => new()
    {
        QuestionId = Guid.NewGuid(),
        Version = 1,
        Title = "t",
        Type = type,
        Options = options.ToList(),
        Project = new ProjectRef { ProjectId = "p1" },
        DeliverableSummary = type is QuestionTypes.Approval or QuestionTypes.DocumentReview ? "deliverable" : null,
    };

    private static TemplateOption Option(string key = "A", string title = "Alpha")
        => new() { OptionId = Guid.NewGuid(), Key = key, Title = title };

    // ── Approval ───────────────────────────────────────────────────────────

    [Fact]
    public void Approval_NoDecision_Fails()
    {
        var result = RespondFormHandler.Validate(Template(QuestionTypes.Approval), new RespondFormInput());
        Assert.False(result.IsValid);
        Assert.Contains("Approve, Reject, or Abstain", result.Error);
    }

    [Fact]
    public void Approval_UnknownDecision_Fails()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: "maybe"));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void Approval_Reject_RequiresComment()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Reject, Comment: "   "));
        Assert.False(result.IsValid);
        Assert.Contains("comment is required", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Approval_Reject_WithComment_Succeeds()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Reject, Comment: "needs work"));
        Assert.True(result.IsValid);
        Assert.Equal(ApprovalDecisions.Reject, result.ApprovalDecision);
        Assert.Equal("needs work", result.Comment);
        Assert.Equal("Reject", result.SelectionLabel);
    }

    [Fact]
    public void Approval_Approve_NoCommentNeeded()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Approve));
        Assert.True(result.IsValid);
        Assert.Null(result.Comment);
    }

    [Fact]
    public void Approval_Abstain_TrimsCommentNullIfBlank()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Abstain, Comment: "   "));
        Assert.True(result.IsValid);
        Assert.Null(result.Comment);
    }

    [Fact]
    public void Approval_DecisionCaseInsensitive_Normalised()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: "APPROVE"));
        Assert.True(result.IsValid);
        Assert.Equal(ApprovalDecisions.Approve, result.ApprovalDecision);
    }

    // ── FreeText ───────────────────────────────────────────────────────────

    [Fact]
    public void FreeText_Empty_Fails()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.FreeText),
            new RespondFormInput(FreeText: "   "));
        Assert.False(result.IsValid);
        Assert.Contains("type a response", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void FreeText_Trimmed_Succeeds()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.FreeText),
            new RespondFormInput(FreeText: "  hello  "));
        Assert.True(result.IsValid);
        Assert.Equal("hello", result.FreeText);
    }

    // ── DocumentReview ─────────────────────────────────────────────────────

    [Fact]
    public void DocumentReview_NoDecision_Fails()
    {
        var template = Template(QuestionTypes.DocumentReview);
        var result = RespondFormHandler.Validate(template, new RespondFormInput());
        Assert.False(result.IsValid);
    }

    [Fact]
    public void DocumentReview_RequestChanges_RequiresComment()
    {
        var template = Template(QuestionTypes.DocumentReview);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.RequestChanges));
        Assert.False(result.IsValid);
        Assert.Contains("comment is required", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void DocumentReview_NoTemplateAttachments_AcceptsApproveWithoutReviewedIds()
    {
        var template = Template(QuestionTypes.DocumentReview);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approve));
        Assert.True(result.IsValid);
        Assert.Null(result.ReviewedAttachmentIds);
    }

    [Fact]
    public void DocumentReview_WithAttachments_RequiresAtLeastOneReviewed()
    {
        var template = Template(QuestionTypes.DocumentReview);
        template.Attachments = [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approve,
            ReviewedAttachmentIds: Array.Empty<Guid>()));
        Assert.False(result.IsValid);
        Assert.Contains("reviewed at least one", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void DocumentReview_WithAttachments_FiltersUnknownIds()
    {
        var aid = Guid.NewGuid();
        var template = Template(QuestionTypes.DocumentReview);
        template.Attachments = [new QuestionAttachment { AttachmentId = aid, Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approve,
            ReviewedAttachmentIds: new[] { aid, Guid.NewGuid() }));
        Assert.True(result.IsValid);
        Assert.Single(result.ReviewedAttachmentIds!);
        Assert.Equal(aid, result.ReviewedAttachmentIds![0]);
    }

    [Fact]
    public void DocumentReview_OnlyUnknownIds_Fails()
    {
        var template = Template(QuestionTypes.DocumentReview);
        template.Attachments = [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.CommentOnly,
            Comment: "ok",
            ReviewedAttachmentIds: new[] { Guid.NewGuid() }));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void DocumentReview_DuplicatesDeduped()
    {
        var aid = Guid.NewGuid();
        var template = Template(QuestionTypes.DocumentReview);
        template.Attachments = [new QuestionAttachment { AttachmentId = aid, Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approve,
            ReviewedAttachmentIds: new[] { aid, aid, aid }));
        Assert.True(result.IsValid);
        Assert.Single(result.ReviewedAttachmentIds!);
    }

    // ── PriorityRanking ────────────────────────────────────────────────────

    [Fact]
    public void Ranking_MissingItems_Fails()
    {
        var o1 = Option("A", "Alpha");
        var o2 = Option("B", "Beta");
        var template = Template(QuestionTypes.PriorityRanking, o1, o2);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            RankedItems: new[] { new RankedItem { OptionId = o1.OptionId, Rank = 1 } }));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void Ranking_WrongOptionId_Fails()
    {
        var o1 = Option("A");
        var o2 = Option("B");
        var template = Template(QuestionTypes.PriorityRanking, o1, o2);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            RankedItems: new[]
            {
                new RankedItem { OptionId = o1.OptionId, Rank = 1 },
                new RankedItem { OptionId = Guid.NewGuid(), Rank = 2 },
            }));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void Ranking_DuplicateRanks_Fails()
    {
        var o1 = Option("A");
        var o2 = Option("B");
        var template = Template(QuestionTypes.PriorityRanking, o1, o2);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            RankedItems: new[]
            {
                new RankedItem { OptionId = o1.OptionId, Rank = 1 },
                new RankedItem { OptionId = o2.OptionId, Rank = 1 },
            }));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void Ranking_GapInRanks_Fails()
    {
        var o1 = Option("A");
        var o2 = Option("B");
        var template = Template(QuestionTypes.PriorityRanking, o1, o2);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            RankedItems: new[]
            {
                new RankedItem { OptionId = o1.OptionId, Rank = 1 },
                new RankedItem { OptionId = o2.OptionId, Rank = 3 },
            }));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void Ranking_FullPermutation_Succeeds()
    {
        var o1 = Option("A");
        var o2 = Option("B");
        var o3 = Option("C");
        var template = Template(QuestionTypes.PriorityRanking, o1, o2, o3);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            RankedItems: new[]
            {
                new RankedItem { OptionId = o2.OptionId, Rank = 1 },
                new RankedItem { OptionId = o3.OptionId, Rank = 2 },
                new RankedItem { OptionId = o1.OptionId, Rank = 3 },
            }));
        Assert.True(result.IsValid);
        Assert.Equal(3, result.RankedItems!.Count);
        Assert.Equal("3 option(s) ranked", result.SelectionLabel);
    }

    [Fact]
    public void Ranking_NoOptionsTemplate_Fails()
    {
        var template = Template(QuestionTypes.PriorityRanking);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            RankedItems: Array.Empty<RankedItem>()));
        Assert.False(result.IsValid);
    }

    // ── SingleChoice fallback ──────────────────────────────────────────────

    [Fact]
    public void SingleChoice_NothingProvided_Fails()
    {
        var template = Template(QuestionTypes.SingleChoice, Option("A"));
        var result = RespondFormHandler.Validate(template, new RespondFormInput());
        Assert.False(result.IsValid);
    }

    [Fact]
    public void SingleChoice_KnownKey_Succeeds()
    {
        var opt = Option("A", "Alpha");
        var template = Template(QuestionTypes.SingleChoice, opt);
        var result = RespondFormHandler.Validate(template, new RespondFormInput(SelectedKey: "A"));
        Assert.True(result.IsValid);
        Assert.Equal(opt.OptionId, result.SelectedOptionId);
        Assert.Equal("A. Alpha", result.SelectionLabel);
    }

    [Fact]
    public void SingleChoice_UnknownKey_Fails()
    {
        var template = Template(QuestionTypes.SingleChoice, Option("A"));
        var result = RespondFormHandler.Validate(template, new RespondFormInput(SelectedKey: "Z"));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void SingleChoice_AttachmentOnly_Succeeds()
    {
        var template = Template(QuestionTypes.SingleChoice, Option("A"));
        var result = RespondFormHandler.Validate(template, new RespondFormInput(UploadedAttachmentCount: 2));
        Assert.True(result.IsValid);
        Assert.Equal("2 file(s) attached", result.SelectionLabel);
    }

    // ── Unsupported type ───────────────────────────────────────────────────

    [Fact]
    public void UnsupportedType_Fails()
    {
        var template = Template("bogus", Option("A"));
        var result = RespondFormHandler.Validate(template, new RespondFormInput(SelectedKey: "A"));
        Assert.False(result.IsValid);
        Assert.Contains("Unsupported", result.Error);
    }
}
