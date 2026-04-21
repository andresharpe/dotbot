using Dotbot.Server.Models;
using Dotbot.Server.Validation;

namespace Dotbot.Server.Tests.Unit;

public class QuestionTemplateValidatorTests
{
    private static QuestionTemplate Template(
        Guid? questionId = null,
        string? projectId = "p1",
        string? type = QuestionTypes.SingleChoice,
        string? deliverableSummary = null,
        List<QuestionAttachment>? attachments = null)
        => new()
        {
            QuestionId = questionId ?? Guid.NewGuid(),
            Version = 1,
            Title = "t",
            Options = [],
            Project = new ProjectRef { ProjectId = projectId! },
            Type = type!,
            DeliverableSummary = deliverableSummary,
            Attachments = attachments,
        };

    [Fact]
    public void MinimalValidSingleChoice_NoErrors()
        => Assert.Empty(QuestionTemplateValidator.Validate(Template()));

    [Fact]
    public void EmptyQuestionId_OneErrorAboutQuestionId()
    {
        var errors = QuestionTemplateValidator.Validate(Template(questionId: Guid.Empty));
        Assert.Single(errors);
        Assert.Contains("questionId", errors[0]);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void MissingProjectId_OneErrorAboutProjectId(string? pid)
    {
        var errors = QuestionTemplateValidator.Validate(Template(projectId: pid));
        Assert.Single(errors);
        Assert.Contains("project.projectId", errors[0]);
    }

    [Fact]
    public void UnknownType_OneErrorListingAllowedValues()
    {
        var errors = QuestionTemplateValidator.Validate(Template(type: "bogus"));
        Assert.Single(errors);
        Assert.Contains("bogus", errors[0]);
        foreach (var allowed in QuestionTypes.AllowedTypes)
            Assert.Contains(allowed, errors[0]);
    }

    [Theory]
    [InlineData(QuestionTypes.SingleChoice)]
    [InlineData(QuestionTypes.MultiChoice)]
    [InlineData(QuestionTypes.FreeText)]
    [InlineData(QuestionTypes.PriorityRanking)]
    public void TypeWithoutDeliverableSummaryRequirement_NoErrorWhenSummaryMissing(string type)
        => Assert.Empty(QuestionTemplateValidator.Validate(Template(type: type)));

    [Theory]
    [InlineData(QuestionTypes.Approval, null)]
    [InlineData(QuestionTypes.Approval, "")]
    [InlineData(QuestionTypes.Approval, "   ")]
    [InlineData(QuestionTypes.DocumentReview, null)]
    [InlineData(QuestionTypes.DocumentReview, "")]
    [InlineData(QuestionTypes.DocumentReview, "   ")]
    public void ApprovalOrDocumentReviewWithoutDeliverableSummary_OneError(string type, string? summary)
    {
        var errors = QuestionTemplateValidator.Validate(Template(type: type, deliverableSummary: summary));
        Assert.Single(errors);
        Assert.Contains("deliverableSummary", errors[0]);
        Assert.Contains(type, errors[0]);
    }

    [Theory]
    [InlineData(QuestionTypes.Approval)]
    [InlineData(QuestionTypes.DocumentReview)]
    public void ApprovalOrDocumentReviewWithDeliverableSummary_NoErrors(string type)
        => Assert.Empty(QuestionTemplateValidator.Validate(
            Template(type: type, deliverableSummary: "ship plan v1")));

    [Fact]
    public void NullAttachments_NoErrors()
        => Assert.Empty(QuestionTemplateValidator.Validate(Template(attachments: null)));

    [Fact]
    public void EmptyAttachmentsList_NoErrors()
        => Assert.Empty(QuestionTemplateValidator.Validate(Template(attachments: [])));

    [Fact]
    public void AttachmentWithOnlyUrl_NoErrors()
        => Assert.Empty(QuestionTemplateValidator.Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = "https://x" }])));

    [Fact]
    public void AttachmentWithOnlyBlobPath_NoErrors()
        => Assert.Empty(QuestionTemplateValidator.Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", BlobPath = "p/q" }])));

    [Fact]
    public void AttachmentWithBothUrlAndBlobPath_OneErrorIndexZero()
    {
        var errors = QuestionTemplateValidator.Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = "https://x", BlobPath = "p/q" }]));
        Assert.Single(errors);
        Assert.Contains("attachments[0]", errors[0]);
    }

    [Fact]
    public void AttachmentWithNeitherUrlNorBlobPath_OneErrorIndexZero()
    {
        var errors = QuestionTemplateValidator.Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n" }]));
        Assert.Single(errors);
        Assert.Contains("attachments[0]", errors[0]);
    }

    [Fact]
    public void AttachmentsMultipleWithSecondInvalid_OneErrorIndexOne()
    {
        var errors = QuestionTemplateValidator.Validate(Template(attachments:
        [
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "a", Url = "https://x" },
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "b" },
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "c", BlobPath = "p/q" },
        ]));
        Assert.Single(errors);
        Assert.Contains("attachments[1]", errors[0]);
    }

    [Fact]
    public void AttachmentsMultipleBothInvalid_TwoErrorsWithCorrectIndices()
    {
        var errors = QuestionTemplateValidator.Validate(Template(attachments:
        [
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "a" },
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "b", Url = "https://x" },
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "c", Url = "https://x", BlobPath = "p/q" },
        ]));
        Assert.Equal(2, errors.Count);
        Assert.Contains("attachments[0]", errors[0]);
        Assert.Contains("attachments[2]", errors[1]);
    }

    [Fact]
    public void MultipleRulesFail_AllErrorsReturned()
    {
        var errors = QuestionTemplateValidator.Validate(Template(
            questionId: Guid.Empty,
            type: "bogus"));
        Assert.Equal(2, errors.Count);
        Assert.Contains("questionId", errors[0]);
        Assert.Contains("bogus", errors[1]);
    }

    [Fact]
    public void ProjectIdEmptyAndApprovalWithoutSummary_TwoErrors()
    {
        var errors = QuestionTemplateValidator.Validate(Template(
            projectId: "",
            type: QuestionTypes.Approval));
        Assert.Equal(2, errors.Count);
        Assert.Contains("project.projectId", errors[0]);
        Assert.Contains("deliverableSummary", errors[1]);
    }

    [Fact]
    public void AllRulesFailSimultaneously_FiveErrorsInRulesArrayOrder()
    {
        var errors = QuestionTemplateValidator.Validate(Template(
            questionId: Guid.Empty,
            projectId: "",
            type: "bogus",
            deliverableSummary: null,
            attachments: [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n" }]));

        // Unknown type short-circuits the deliverable-summary rule (the
        // conditional doesn't match 'bogus'), so four errors, not five.
        Assert.Equal(4, errors.Count);
        Assert.Contains("questionId", errors[0]);
        Assert.Contains("project.projectId", errors[1]);
        Assert.Contains("bogus", errors[2]);
        Assert.Contains("attachments[0]", errors[3]);
    }
}
