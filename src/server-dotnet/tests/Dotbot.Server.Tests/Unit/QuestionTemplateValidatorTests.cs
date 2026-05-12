using Dotbot.Server.Models;
using Dotbot.Server.Validation;
using Microsoft.Extensions.Options;

namespace Dotbot.Server.Tests.Unit;

public class QuestionTemplateValidatorTests
{
    private static QuestionTemplateValidator NewValidator(
        int? maxAttachments = null,
        int? maxReferenceLinks = null)
        => new(Options.Create(new QuestionTemplateValidationSettings
        {
            MaxAttachments = maxAttachments ?? QuestionTemplateValidationSettings.DefaultMaxAttachments,
            MaxReferenceLinks = maxReferenceLinks ?? QuestionTemplateValidationSettings.DefaultMaxReferenceLinks,
        }));

    private static IReadOnlyList<string> Validate(QuestionTemplate t) => NewValidator().Validate(t);

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
        => Assert.Empty(Validate(Template()));

    [Fact]
    public void EmptyQuestionId_OneErrorAboutQuestionId()
    {
        var errors = Validate(Template(questionId: Guid.Empty));
        Assert.Single(errors);
        Assert.Contains("questionId", errors[0]);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void MissingProjectId_OneErrorAboutProjectId(string? pid)
    {
        var errors = Validate(Template(projectId: pid));
        Assert.Single(errors);
        Assert.Contains("project.projectId", errors[0]);
    }

    [Fact]
    public void UnknownType_OneErrorListingAllowedValues()
    {
        var errors = Validate(Template(type: "bogus"));
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
        => Assert.Empty(Validate(Template(type: type)));

    [Theory]
    [InlineData(QuestionTypes.Approval, null)]
    [InlineData(QuestionTypes.Approval, "")]
    [InlineData(QuestionTypes.Approval, "   ")]
    [InlineData(QuestionTypes.DocumentReview, null)]
    [InlineData(QuestionTypes.DocumentReview, "")]
    [InlineData(QuestionTypes.DocumentReview, "   ")]
    public void ApprovalOrDocumentReviewWithoutDeliverableSummary_OneError(string type, string? summary)
    {
        var errors = Validate(Template(type: type, deliverableSummary: summary));
        Assert.Single(errors);
        Assert.Contains("deliverableSummary", errors[0]);
        Assert.Contains(type, errors[0]);
    }

    [Theory]
    [InlineData(QuestionTypes.Approval)]
    [InlineData(QuestionTypes.DocumentReview)]
    public void ApprovalOrDocumentReviewWithDeliverableSummary_NoErrors(string type)
        => Assert.Empty(Validate(
            Template(type: type, deliverableSummary: "ship plan v1")));

    [Fact]
    public void NullAttachments_NoErrors()
        => Assert.Empty(Validate(Template(attachments: null)));

    [Fact]
    public void EmptyAttachmentsList_NoErrors()
        => Assert.Empty(Validate(Template(attachments: [])));

    [Fact]
    public void AttachmentWithOnlyUrl_NoErrors()
        => Assert.Empty(Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = "https://x" }])));

    [Fact]
    public void AttachmentWithOnlyBlobPath_NoErrors()
        => Assert.Empty(Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", BlobPath = "p/q" }])));

    [Fact]
    public void AttachmentWithBothUrlAndBlobPath_OneErrorIndexZero()
    {
        var errors = Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = "https://x", BlobPath = "p/q" }]));
        Assert.Single(errors);
        Assert.Contains("attachments[0]", errors[0]);
    }

    [Fact]
    public void AttachmentWithNeitherUrlNorBlobPath_OneErrorIndexZero()
    {
        var errors = Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n" }]));
        Assert.Single(errors);
        Assert.Contains("attachments[0]", errors[0]);
    }

    [Fact]
    public void AttachmentsMultipleWithSecondInvalid_OneErrorIndexOne()
    {
        var errors = Validate(Template(attachments:
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
        var errors = Validate(Template(attachments:
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
        var errors = Validate(Template(
            questionId: Guid.Empty,
            type: "bogus"));
        Assert.Equal(2, errors.Count);
        Assert.Contains("questionId", errors[0]);
        Assert.Contains("bogus", errors[1]);
    }

    [Fact]
    public void ProjectIdEmptyAndApprovalWithoutSummary_TwoErrors()
    {
        var errors = Validate(Template(
            projectId: "",
            type: QuestionTypes.Approval));
        Assert.Equal(2, errors.Count);
        Assert.Contains("project.projectId", errors[0]);
        Assert.Contains("deliverableSummary", errors[1]);
    }

    [Fact]
    public void NullProject_OneErrorAboutProjectId_NoNullReferenceException()
    {
        var t = Template();
        t.Project = null!;

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("project.projectId", errors[0]);
    }

    [Theory]
    [InlineData("javascript:alert(1)")]
    [InlineData("http://not-https")]
    [InlineData("data:text/html,<script>alert(1)</script>")]
    [InlineData("not-a-url")]
    [InlineData("/relative-only")]
    // Non-standard IP-literal forms browsers resolve to loopback / private IPs
    [InlineData("https://2130706433")]            // decimal integer = 127.0.0.1
    [InlineData("https://0x7f000001")]             // hex = 127.0.0.1
    [InlineData("https://localhost.")]             // trailing-dot localhost bypass
    [InlineData("https://user:pass@example.com")]  // userinfo
    public void AttachmentWithUnsafeUrl_OneErrorAboutUrl(string url)
    {
        var errors = Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = url }]));

        Assert.Single(errors);
        Assert.Contains("attachments[0].url", errors[0]);
        Assert.Contains("https", errors[0]);
    }

    [Theory]
    [InlineData("/abs/path")]
    [InlineData("..\\winnt\\system32")]
    [InlineData("a/../b")]
    [InlineData("./leading-dot")]
    [InlineData("has\\backslash")]
    [InlineData("trailing/../traversal")]
    public void AttachmentWithUnsafeBlobPath_OneErrorAboutBlobPath(string bp)
    {
        var errors = Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", BlobPath = bp }]));

        Assert.Single(errors);
        Assert.Contains("attachments[0].blobPath", errors[0]);
    }

    [Theory]
    [InlineData("templates/p1/q1/spec.pdf")]
    [InlineData("attachments/abc/file.png")]
    [InlineData("single-segment")]
    public void AttachmentWithSafeBlobPath_NoErrors(string bp)
        => Assert.Empty(Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", BlobPath = bp }])));

    [Fact]
    public void NullReferenceLinks_NoErrors()
        => Assert.Empty(Validate(Template()));

    [Fact]
    public void ReferenceLinkWithSafeHttpsUrl_NoErrors()
    {
        var t = Template();
        t.ReferenceLinks = [new ReferenceLink { Label = "ADR", Url = "https://adrs/1" }];

        Assert.Empty(Validate(t));
    }

    [Theory]
    [InlineData("javascript:alert(1)")]
    [InlineData("http://not-https")]
    [InlineData("data:text/html")]
    [InlineData("/relative")]
    public void ReferenceLinkWithUnsafeUrl_OneErrorAboutLink(string url)
    {
        var t = Template();
        t.ReferenceLinks = [new ReferenceLink { Label = "bad", Url = url }];

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("referenceLinks[0].url", errors[0]);
        Assert.Contains("https", errors[0]);
    }

    [Fact]
    public void AttachmentsOverCap_OneErrorShortCircuitsPerItemChecks()
    {
        var attachments = Enumerable.Range(0, QuestionTemplateValidationSettings.DefaultMaxAttachments + 1)
            .Select(_ => new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n" }) // invalid per-item (no Url/BlobPath)
            .ToList();

        var errors = Validate(Template(attachments: attachments));

        Assert.Single(errors);
        Assert.Contains("attachments", errors[0]);
        Assert.Contains(QuestionTemplateValidationSettings.DefaultMaxAttachments.ToString(), errors[0]);
    }

    [Fact]
    public void ReferenceLinksOverCap_OneErrorShortCircuitsPerItemChecks()
    {
        var t = Template();
        t.ReferenceLinks = Enumerable.Range(0, QuestionTemplateValidationSettings.DefaultMaxReferenceLinks + 1)
            .Select(_ => new ReferenceLink { Label = "x", Url = "not-safe" }) // invalid per-item (not https)
            .ToList();

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("referenceLinks", errors[0]);
        Assert.Contains(QuestionTemplateValidationSettings.DefaultMaxReferenceLinks.ToString(), errors[0]);
    }

    [Fact]
    public void CustomMaxAttachments_HonouredFromInjectedSettings()
    {
        var attachments = Enumerable.Range(0, 4)
            .Select(_ => new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = "https://ok" })
            .ToList();
        var validator = NewValidator(maxAttachments: 3);

        var errors = validator.Validate(Template(attachments: attachments));

        Assert.Single(errors);
        Assert.Contains("attachments", errors[0]);
        Assert.Contains("3", errors[0]);
    }

    [Fact]
    public void CustomMaxReferenceLinks_HonouredFromInjectedSettings()
    {
        var t = Template();
        t.ReferenceLinks = Enumerable.Range(0, 4)
            .Select(_ => new ReferenceLink { Label = "x", Url = "https://ok" })
            .ToList();
        var validator = NewValidator(maxReferenceLinks: 3);

        var errors = validator.Validate(t);

        Assert.Single(errors);
        Assert.Contains("referenceLinks", errors[0]);
        Assert.Contains("3", errors[0]);
    }

    [Fact]
    public void DuplicateOptionId_OneErrorMentioningDuplicateOptionId()
    {
        var shared = Guid.NewGuid();
        var t = Template();
        t.Options =
        [
            new TemplateOption { OptionId = shared, Key = "a", Title = "A" },
            new TemplateOption { OptionId = shared, Key = "b", Title = "B" },
        ];

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("duplicate optionId", errors[0]);
        Assert.Contains(shared.ToString(), errors[0]);
    }

    [Fact]
    public void DuplicateOptionKey_OneErrorMentioningDuplicateKey()
    {
        var t = Template();
        t.Options =
        [
            new TemplateOption { OptionId = Guid.NewGuid(), Key = "same", Title = "A" },
            new TemplateOption { OptionId = Guid.NewGuid(), Key = "same", Title = "B" },
        ];

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("duplicate key", errors[0]);
        Assert.Contains("same", errors[0]);
    }

    [Fact]
    public void DistinctOptionKeysWithDifferentCasing_NoErrors_OrdinalComparison()
    {
        var t = Template();
        t.Options =
        [
            new TemplateOption { OptionId = Guid.NewGuid(), Key = "Accept", Title = "A" },
            new TemplateOption { OptionId = Guid.NewGuid(), Key = "accept", Title = "B" },
        ];

        Assert.Empty(Validate(t));
    }

    [Theory]
    // Loopback — never a review target
    [InlineData("https://127.0.0.1/x")]
    [InlineData("https://localhost/x")]
    [InlineData("https://[::ffff:127.0.0.1]/x")]
    // Link-local — includes AWS/Azure IMDS at 169.254.169.254, also IPv6 fe80::/10
    [InlineData("https://169.254.169.254/metadata")]
    [InlineData("https://[::ffff:169.254.169.254]/metadata")]
    // Userinfo (phishing pattern)
    [InlineData("https://attacker.example.com@internal.corp/x")]
    public void AttachmentUrl_InternalOrDeceptive_Rejected(string url)
    {
        var errors = Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = url }]));

        Assert.Single(errors);
        Assert.Contains("attachments[0].url", errors[0]);
    }

    [Theory]
    // Public hosts — legit
    [InlineData("https://example.com/legit")]
    [InlineData("https://docs.example.com/a/b")]
    // Corporate intranet — RFC 1918 IPv4, common review targets in enterprise deployments
    [InlineData("https://10.0.0.1/x")]
    [InlineData("https://172.16.0.1/x")]
    [InlineData("https://192.168.1.1/x")]
    // Corporate intranet hostnames — .internal, .local, .corp DNS suffixes
    [InlineData("https://jira.corp.internal/browse/ABC-1")]
    [InlineData("https://wiki.corp.local/page")]
    [InlineData("https://confluence.internal.company.com/page")]
    // IPv6 ULA (fc00::/7) — enterprise uses
    [InlineData("https://[fd00::1]/x")]
    // IPv4-mapped private — private IPv4 allowed, so mapped form allowed too
    [InlineData("https://[::ffff:10.0.0.1]/x")]
    [InlineData("https://[::ffff:192.168.1.1]/x")]
    public void AttachmentUrl_PublicOrIntranet_Accepted(string url)
        => Assert.Empty(Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = url }])));

    [Theory]
    [InlineData("https://127.0.0.1/x")]
    [InlineData("https://169.254.169.254/metadata")]
    [InlineData("https://attacker.example.com@internal.corp/x")]
    [InlineData("https://localhost/x")]
    public void ReferenceLinkUrl_InternalOrDeceptive_Rejected(string url)
    {
        var t = Template();
        t.ReferenceLinks = [new ReferenceLink { Label = "bad", Url = url }];

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("referenceLinks[0].url", errors[0]);
    }

    [Theory]
    [InlineData("https://[fe80::1]/x")]              // IPv6 link-local
    [InlineData("https://[fe80::dead:beef]/x")]      // IPv6 link-local, longer form
    [InlineData("https://[::]/x")]                   // IPv6 unspecified
    public void AttachmentUrl_IPv6InternalRange_Rejected(string url)
    {
        var errors = Validate(Template(attachments:
            [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n", Url = url }]));

        Assert.Single(errors);
        Assert.Contains("attachments[0].url", errors[0]);
    }

    [Fact]
    public void AttachmentsListWithNullElement_OneErrorIndexed_NoNullReferenceException()
    {
        var errors = Validate(Template(attachments:
            new List<QuestionAttachment> { null! }));

        Assert.Single(errors);
        Assert.Contains("attachments[0]", errors[0]);
        Assert.Contains("null", errors[0]);
    }

    [Fact]
    public void ReferenceLinksListWithNullElement_OneErrorIndexed_NoNullReferenceException()
    {
        var t = Template();
        t.ReferenceLinks = new List<ReferenceLink> { null! };

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("referenceLinks[0]", errors[0]);
        Assert.Contains("null", errors[0]);
    }

    [Fact]
    public void OptionsListWithNullElement_OneErrorIndexed_NoNullReferenceException()
    {
        var t = Template();
        t.Options = new List<TemplateOption> { null! };

        var errors = Validate(t);

        Assert.Single(errors);
        Assert.Contains("options[0]", errors[0]);
        Assert.Contains("null", errors[0]);
    }

    [Fact]
    public void AllRulesFailSimultaneously_MultipleErrorsInRulesArrayOrder()
    {
        var errors = Validate(Template(
            questionId: Guid.Empty,
            projectId: "",
            type: "bogus",
            deliverableSummary: null,
            attachments: [new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "n" }]));

        Assert.Equal(4, errors.Count);
        Assert.Contains("questionId", errors[0]);
        Assert.Contains("project.projectId", errors[1]);
        Assert.Contains("bogus", errors[2]);
        Assert.Contains("attachments[0]", errors[3]);
    }
}
