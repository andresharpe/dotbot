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
    public void ProjectName_PrefersNameThenProjectId(string? name, string projectId, string expected)
    {
        var s = Build(Template(projectId: projectId, projectName: name));
        Assert.Equal(expected, s.ProjectName);
    }

    [Theory]
    [InlineData("summary", "ignored", "summary")]    // explicit summary wins
    [InlineData(null, "legacy desc", "legacy desc")] // null summary → Description fallback
    [InlineData(null, null, null)]                   // both null → null
    public void DeliverableSummary_FallbackChain(string? summary, string? description, string? expected)
    {
        var s = Build(Template(deliverableSummary: summary, description: description));
        Assert.Equal(expected, s.DeliverableSummary);
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
        });

        var atts = Build(t).Attachments;
        Assert.Equal(2, atts.Count);

        Assert.Equal("spec.pdf", atts[0].Name);
        Assert.Equal("application/pdf", atts[0].ContentType);
        Assert.Equal(1024, atts[0].SizeBytes);

        Assert.Equal("blob.bin", atts[1].Name);
        Assert.Equal("application/octet-stream", atts[1].ContentType);
        Assert.Null(atts[1].SizeBytes);
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

    [Fact]
    public void DueBy_ComputedFromEscalateAfterDays()
    {
        var created = new DateTime(2026, 1, 10, 9, 0, 0, DateTimeKind.Utc);
        var t = Template(deliveryDefaults: new DeliveryDefaults { EscalateAfterDays = 3 });
        var s = Build(t, instance: Instance(questionId: t.QuestionId, createdAt: created));

        Assert.Equal(created.AddDays(3), s.DueBy);
    }

    [Theory]
    [InlineData(false, null)]   // no DeliveryDefaults at all
    [InlineData(true, null)]    // DeliveryDefaults set, EscalateAfterDays null
    public void DueBy_NullWhenNoEscalation(bool hasDefaults, int? escalateAfterDays)
    {
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
}
