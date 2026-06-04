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
        DeliverableSummary = type == QuestionTypes.Approval ? "deliverable" : null,
    };

    private static TemplateOption Option(string key = "A", string title = "Alpha")
        => new() { OptionId = Guid.NewGuid(), Key = key, Title = title };

    // ── Approval (no attachments) ──────────────────────────────────────────

    [Fact]
    public void Approval_NoDecision_Fails()
    {
        var result = RespondFormHandler.Validate(Template(QuestionTypes.Approval), new RespondFormInput());
        Assert.False(result.IsValid);
        Assert.Contains("Approve or Reject", result.Error);
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
    public void Approval_Rejected_RequiresComment()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Rejected, Comment: "   "));
        Assert.False(result.IsValid);
        Assert.Contains("comment is required", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Approval_Rejected_WithComment_Succeeds()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Rejected, Comment: "needs work"));
        Assert.True(result.IsValid);
        Assert.Equal(ApprovalDecisions.Rejected, result.ApprovalDecision);
        Assert.Equal("needs work", result.Comment);
        Assert.Equal("Reject", result.SelectionLabel);
    }

    [Fact]
    public void Approval_Approved_NoCommentNeeded()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: ApprovalDecisions.Approved));
        Assert.True(result.IsValid);
        Assert.Null(result.Comment);
    }

    [Fact]
    public void Approval_DecisionCaseInsensitive_Normalised()
    {
        var result = RespondFormHandler.Validate(
            Template(QuestionTypes.Approval),
            new RespondFormInput(ApprovalDecision: "APPROVED"));
        Assert.True(result.IsValid);
        Assert.Equal(ApprovalDecisions.Approved, result.ApprovalDecision);
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

    // ── Approval with attachments (formerly DocumentReview) ────────────────

    [Fact]
    public void ApprovalWithAttachments_NoDecision_Fails()
    {
        var template = Template(QuestionTypes.Approval);
        template.Attachments = [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput());
        Assert.False(result.IsValid);
    }

    [Fact]
    public void ApprovalWithAttachments_Rejected_RequiresComment()
    {
        var template = Template(QuestionTypes.Approval);
        template.Attachments = [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Rejected));
        Assert.False(result.IsValid);
        Assert.Contains("comment is required", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ApprovalWithAttachments_RequiresAtLeastOneReviewed()
    {
        var template = Template(QuestionTypes.Approval);
        template.Attachments = [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approved,
            ReviewedAttachmentIds: Array.Empty<Guid>()));
        Assert.False(result.IsValid);
        Assert.Contains("reviewed at least one", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ApprovalWithAttachments_FiltersUnknownIds()
    {
        var aid = Guid.NewGuid();
        var template = Template(QuestionTypes.Approval);
        template.Attachments = [new QuestionAttachment { AttachmentId = aid, Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approved,
            ReviewedAttachmentIds: new[] { aid, Guid.NewGuid() }));
        Assert.True(result.IsValid);
        Assert.Single(result.ReviewedAttachmentIds!);
        Assert.Equal(aid, result.ReviewedAttachmentIds![0]);
    }

    [Fact]
    public void ApprovalWithAttachments_OnlyUnknownIds_Fails()
    {
        var template = Template(QuestionTypes.Approval);
        template.Attachments = [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approved,
            ReviewedAttachmentIds: new[] { Guid.NewGuid() }));
        Assert.False(result.IsValid);
    }

    [Fact]
    public void ApprovalWithAttachments_DuplicatesDeduped()
    {
        var aid = Guid.NewGuid();
        var template = Template(QuestionTypes.Approval);
        template.Attachments = [new QuestionAttachment { AttachmentId = aid, Name = "spec", BlobPath = "x" }];
        var result = RespondFormHandler.Validate(template, new RespondFormInput(
            ApprovalDecision: ApprovalDecisions.Approved,
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

    [Fact]
    public void SingleChoice_FreeText_WhenNotAllowed_Fails()
    {
        var template = Template(QuestionTypes.SingleChoice, Option("A"));
        // ResponseSettings null → AllowFreeText defaults to false.
        var result = RespondFormHandler.Validate(
            template,
            new RespondFormInput(SelectedKey: "A", FreeText: "smuggled"));
        Assert.False(result.IsValid);
        Assert.Contains("not allowed", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SingleChoice_FreeText_OnlyAndNotAllowed_Fails()
    {
        var template = Template(QuestionTypes.SingleChoice, Option("A"));
        var result = RespondFormHandler.Validate(template, new RespondFormInput(FreeText: "hello"));
        Assert.False(result.IsValid);
        Assert.Contains("not allowed", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SingleChoice_FreeText_WhenAllowed_Succeeds()
    {
        var template = Template(QuestionTypes.SingleChoice, Option("A"));
        template.ResponseSettings = new ResponseSettings { AllowFreeText = true };
        var result = RespondFormHandler.Validate(template, new RespondFormInput(FreeText: "hello"));
        Assert.True(result.IsValid);
        Assert.Equal("hello", result.FreeText);
    }

    [Fact]
    public void SingleChoice_FreeText_WhenAllowed_AndSelected_BothPersist()
    {
        var opt = Option("A", "Alpha");
        var template = Template(QuestionTypes.SingleChoice, opt);
        template.ResponseSettings = new ResponseSettings { AllowFreeText = true };
        var result = RespondFormHandler.Validate(
            template,
            new RespondFormInput(SelectedKey: "A", FreeText: "and a note"));
        Assert.True(result.IsValid);
        Assert.Equal("A", result.SelectedKey);
        Assert.Equal("and a note", result.FreeText);
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
