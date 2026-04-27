using Dotbot.Server.Models;
using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Tests.Unit;

public class NotificationSummaryBuilderTests
{
    private const string DefaultRespondUrl = "https://example/respond/abc";
    private static readonly NotificationSummaryBuilder Builder = new();

    private static QuestionTemplate Template(
        Guid? questionId = null,
        string title = "Approve architecture v2",
        string type = "approval",
        string projectId = "proj-1",
        string? projectName = "Project One",
        string? description = null,
        string? context = null,
        string? deliverableSummary = null,
        List<QuestionAttachment>? attachments = null,
        List<ReferenceLink>? referenceLinks = null,
        DeliveryDefaults? deliveryDefaults = null)
        => new()
        {
            QuestionId = questionId ?? Guid.NewGuid(),
            Version = 1,
            Title = title,
            Type = type,
            Description = description,
            Context = context,
            Options = [],
            Project = new ProjectRef { ProjectId = projectId, Name = projectName },
            DeliverableSummary = deliverableSummary,
            Attachments = attachments,
            ReferenceLinks = referenceLinks,
            DeliveryDefaults = deliveryDefaults,
        };

    private static QuestionInstance Instance(
        Guid? questionId = null,
        string projectId = "proj-1",
        DateTime? createdAt = null)
        => new()
        {
            InstanceId = Guid.NewGuid(),
            QuestionId = questionId ?? Guid.NewGuid(),
            QuestionVersion = 1,
            ProjectId = projectId,
            CreatedAt = createdAt ?? new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc),
        };

    private static NotificationSummary Build(
        QuestionTemplate template,
        QuestionInstance? instance = null,
        string respondUrl = DefaultRespondUrl,
        bool isReminder = false)
        => Builder.Build(template, instance ?? Instance(questionId: template.QuestionId), respondUrl, isReminder);

    [Fact]
    public void Header_TitleAndTypeRoundTrip()
    {
        var s = Build(Template(title: "Approve v2", type: "approval"));
        Assert.Equal("Approve v2", s.QuestionTitle);
        Assert.Equal("approval", s.QuestionType);
    }

    [Theory]
    [InlineData("Acme", "proj-x", "Acme")]    // explicit name wins
    [InlineData(null, "proj-x", "proj-x")]    // null name → projectId fallback
    [InlineData("", "proj-x", "proj-x")]      // empty name → projectId fallback
    [InlineData("   ", "proj-x", "proj-x")]   // whitespace name → projectId fallback
    public void ProjectName_PrefersNameThenProjectId(string? name, string projectId, string expected)
    {
        var s = Build(Template(projectId: projectId, projectName: name));
        Assert.Equal(expected, s.ProjectName);
    }

    [Theory]
    [InlineData("summary", "summary")]   // explicit value passes through
    [InlineData(null, null)]             // null stays null — legacy templates render Context separately
    public void DeliverableSummary_PassesThroughOrStaysNull(string? summary, string? expected)
    {
        var s = Build(Template(deliverableSummary: summary, description: "ignored"));
        Assert.Equal(expected, s.DeliverableSummary);
    }

    [Theory]
    [InlineData("longer background block", "longer background block")]
    [InlineData(null, null)]
    public void Context_PassesThroughOrStaysNull(string? context, string? expected)
    {
        var s = Build(Template(context: context));
        Assert.Equal(expected, s.Context);
    }

    [Fact]
    public void BatchQuestions_SingleEntryFromTemplate()
    {
        var qid = Guid.NewGuid();
        var t = Template(questionId: qid, title: "Q1", type: "approval");
        var bq = Assert.Single(Build(t).BatchQuestions);

        Assert.Equal(qid, bq.QuestionId);
        Assert.Equal("Q1", bq.Title);
        Assert.Equal("approval", bq.Type);
    }

    [Fact]
    public void BatchQuestions_AnsweredStateAtDefault()
    {
        // Locks the deferred-population contract — see #289.
        var bq = Assert.Single(Build(Template()).BatchQuestions);
        Assert.False(bq.IsAnswered);
        Assert.Null(bq.AnsweredSummary);
    }

    [Fact]
    public void Attachments_MappedWithMediaTypeFallback()
    {
        var t = Template(attachments: new List<QuestionAttachment>
        {
            new() { AttachmentId = Guid.NewGuid(), Name = "spec.pdf", MediaType = "application/pdf", SizeBytes = 1024 },
            new() { AttachmentId = Guid.NewGuid(), Name = "blob.bin", MediaType = null, SizeBytes = null },
            new() { AttachmentId = Guid.NewGuid(), Name = "blank.dat", MediaType = "   " },
        });

        var atts = Build(t).Attachments;
        Assert.Equal(3, atts.Count);

        Assert.Equal("spec.pdf", atts[0].Name);
        Assert.Equal("application/pdf", atts[0].ContentType);
        Assert.Equal(1024, atts[0].SizeBytes);

        Assert.Equal("blob.bin", atts[1].Name);
        Assert.Equal("application/octet-stream", atts[1].ContentType);
        Assert.Null(atts[1].SizeBytes);

        Assert.Equal("blank.dat", atts[2].Name);
        Assert.Equal("application/octet-stream", atts[2].ContentType);
    }

    [Fact]
    public void ReferenceLinks_MappedToReviewLinkRefs()
    {
        var t = Template(referenceLinks: new List<ReferenceLink>
        {
            new() { Label = "ADR-007", Url = "https://example/adr/7" },
        });

        var link = Assert.Single(Build(t).ReviewLinks);
        Assert.Equal("ADR-007", link.Title);
        Assert.Equal("https://example/adr/7", link.Url);
        Assert.Null(link.Type);
    }

    [Fact]
    public void EmptyCollections_StayEmptyNotNull()
    {
        var s = Build(Template(attachments: null, referenceLinks: null));
        Assert.Empty(s.Attachments);
        Assert.Empty(s.ReviewLinks);
    }

    [Theory]
    [InlineData(false, null)]   // no DeliveryDefaults at all
    [InlineData(true, null)]    // DeliveryDefaults set, EscalateAfterDays null
    [InlineData(true, 3)]       // DeliveryDefaults set, EscalateAfterDays present — still null in PR-3
    public void DueBy_AlwaysNullInPR3(bool hasDefaults, int? escalateAfterDays)
    {
        // PRD §4.5 line 642 derives DueBy from InstanceRecipient.SentAt, which is per-recipient.
        // DeliveryOrchestrator computes it in PR-6/#287 alongside RespondUrl personalisation.
        var t = Template(deliveryDefaults: hasDefaults
            ? new DeliveryDefaults { EscalateAfterDays = escalateAfterDays }
            : null);
        Assert.Null(Build(t).DueBy);
    }

    [Fact]
    public void Parameters_FlowThrough()
    {
        var s = Build(Template(), respondUrl: "https://m/respond/xyz", isReminder: true);
        Assert.Equal("https://m/respond/xyz", s.RespondUrl);
        Assert.True(s.IsReminder);
    }

    [Fact]
    public void Build_ThrowsWhenInstanceQuestionIdDoesNotMatchTemplate()
    {
        // Runtime check (not Debug.Assert) so the contract holds in Release builds.
        var template = Template(questionId: Guid.NewGuid());
        var instance = Instance(questionId: Guid.NewGuid());
        var ex = Assert.Throws<ArgumentException>(
            () => Builder.Build(template, instance, DefaultRespondUrl, isReminder: false));
        Assert.Equal("instance", ex.ParamName);
    }
}
