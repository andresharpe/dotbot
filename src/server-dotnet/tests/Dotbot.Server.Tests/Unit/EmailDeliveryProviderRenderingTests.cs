using Dotbot.Server.Models;
using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Tests.Unit;

public class EmailDeliveryProviderRenderingTests
{
    private const string DefaultRespondUrl = "https://example/respond/abc";
    private const string DefaultDisplayName = "Andre Sharpe";

    private static NotificationSummary MakeFullSummary() => new()
    {
        QuestionTitle = "Approve architecture v2",
        QuestionType = "approval",
        ProjectName = "Project One",
        DeliverableSummary = "Sign-off needed on the v2 architecture proposal.",
        Context = "We are choosing between two patterns; a third is out due to cost.",
        BatchQuestions =
        {
            new BatchQuestionRef
            {
                QuestionId = Guid.NewGuid(),
                Title = "Pick the migration strategy",
                Type = "approval",
                IsAnswered = true,
                AnsweredSummary = "Approved",
            },
            new BatchQuestionRef
            {
                QuestionId = Guid.NewGuid(),
                Title = "Confirm rollback window",
                Type = "freeText",
                IsAnswered = false,
            },
        },
        Attachments =
        {
            new AttachmentRef { Name = "diagram.pdf", ContentType = "application/pdf", SizeBytes = 245_678 },
            new AttachmentRef { Name = "spec.docx", ContentType = "application/vnd.openxmlformats", SizeBytes = null },
        },
        ReviewLinks =
        {
            new ReviewLinkRef { Title = "Confluence design doc", Url = "https://example.atlassian.net/wiki/x", Type = "review" },
        },
        RespondUrl = DefaultRespondUrl,
        DueBy = new DateTime(2026, 5, 1, 17, 0, 0, DateTimeKind.Utc),
        IsReminder = false,
    };

    [Fact]
    public void Summary_FullPayload_RendersAllSectionsInOrder()
    {
        var html = EmailDeliveryProvider.BuildEmailHtmlFromSummary(MakeFullSummary(), DefaultDisplayName);

        // Header — project banner, title, type-badge
        Assert.Contains("Project One", html);
        Assert.Contains("Approve architecture v2", html);
        Assert.Contains(">approval<", html);

        // Deliverable summary + Context
        Assert.Contains("Sign-off needed on the v2 architecture proposal.", html);
        Assert.Contains("We are choosing between two patterns", html);

        // Batch entries
        Assert.Contains("Pick the migration strategy", html);
        Assert.Contains("&#10003;", html);                 // ✓ marker on answered entry (Outlook-safe entity)
        Assert.Contains("Approved", html);                 // AnsweredSummary text
        Assert.Contains("Confirm rollback window", html);

        // Attachments — name + formatted size
        Assert.Contains("diagram.pdf", html);
        Assert.Contains("239.9 KB", html);                   // 245_678 / 1024 = 239
        Assert.Contains("spec.docx", html);
        // FormatBytes(null) returns the literal em-dash; HtmlEncode renders it as the &#8212; entity.
        // Accept either rendering — pin truthfulness without assuming the encoder's output form.
        Assert.True(html.Contains("—") || html.Contains("&#8212;"),
            "expected em-dash placeholder for unsized attachment");

        // Review link — direct <a href>
        Assert.Contains("href=\"https://example.atlassian.net/wiki/x\"", html);
        Assert.Contains("Confluence design doc", html);
        Assert.Contains("requires review", html);          // suffix when Type == "review"

        // Due by
        Assert.Contains("Due by:", html);
        Assert.Contains("2026-05-01 17:00 UTC", html);

        // CTA href = Summary.RespondUrl
        Assert.Contains($"href=\"{DefaultRespondUrl}\"", html);
        Assert.Contains("Respond Now", html);

        // Ordering — header → summary → context → batch → attachments → review-links → due-by → CTA
        var idxTitle = html.IndexOf("Approve architecture v2", StringComparison.Ordinal);
        var idxDeliverable = html.IndexOf("Sign-off needed", StringComparison.Ordinal);
        var idxContext = html.IndexOf("two patterns", StringComparison.Ordinal);
        var idxBatch = html.IndexOf("Pick the migration strategy", StringComparison.Ordinal);
        var idxAttach = html.IndexOf("diagram.pdf", StringComparison.Ordinal);
        var idxReview = html.IndexOf("Confluence design doc", StringComparison.Ordinal);
        var idxDue = html.IndexOf("Due by:", StringComparison.Ordinal);
        var idxCta = html.IndexOf("Respond Now</a>", StringComparison.Ordinal);
        Assert.True(idxTitle < idxDeliverable, "title before deliverable summary");
        Assert.True(idxDeliverable < idxContext, "deliverable before context");
        Assert.True(idxContext < idxBatch, "context before batch");
        Assert.True(idxBatch < idxAttach, "batch before attachments");
        Assert.True(idxAttach < idxReview, "attachments before review links");
        Assert.True(idxReview < idxDue, "review links before due-by");
        Assert.True(idxDue < idxCta, "due-by before CTA");
    }

    [Fact]
    public void Summary_Minimal_OmitsOptionalSections()
    {
        var s = MakeFullSummary();
        s.DeliverableSummary = null;
        s.Context = null;
        s.Attachments.Clear();
        s.ReviewLinks.Clear();
        s.DueBy = null;

        var html = EmailDeliveryProvider.BuildEmailHtmlFromSummary(s, DefaultDisplayName);

        Assert.Contains("Approve architecture v2", html);                      // title still present
        Assert.Contains("Project One", html);                                  // project banner still present
        Assert.Contains($"href=\"{DefaultRespondUrl}\"", html);                // CTA still present

        Assert.DoesNotContain(">Attachments<", html);                          // section heading omitted
        Assert.DoesNotContain(">Review links<", html);
        Assert.DoesNotContain("Due by:", html);
    }

    [Fact]
    public void Summary_IsReminderTrue_RendersReminderBanner()
    {
        var s = MakeFullSummary();
        s.IsReminder = true;

        var html = EmailDeliveryProvider.BuildEmailHtmlFromSummary(s, DefaultDisplayName);

        Assert.Contains("#FFF8E8", html);                                       // reminder panel background
        Assert.Contains("&#9888;", html);                                       // ⚠ entity
        Assert.Contains("This question is still awaiting your response.", html);
    }

    [Fact]
    public void NullSummary_LegacyFallback_RendersUnchanged()
    {
        var template = new QuestionTemplate
        {
            QuestionId = Guid.NewGuid(),
            Version = 1,
            Title = "Pick a deployment strategy",
            Type = "singleChoice",
            Context = "Trading off speed against safety.",
            Project = new ProjectRef { ProjectId = "proj-1", Name = "Project One" },
            Options =
            [
                new TemplateOption { OptionId = Guid.NewGuid(), Key = "A", Title = "Big-bang", Summary = "Fast but risky" },
                new TemplateOption { OptionId = Guid.NewGuid(), Key = "B", Title = "Phased", Summary = "Slow but safe" },
            ],
        };

        var html = EmailDeliveryProvider.BuildEmailHtml(template, "https://x/legacy", isReminder: true, DefaultDisplayName);

        // Title + context + options table preserved
        Assert.Contains("Pick a deployment strategy", html);
        Assert.Contains("Trading off speed against safety.", html);
        Assert.Contains(">A<", html);
        Assert.Contains("Big-bang", html);
        Assert.Contains(">B<", html);
        Assert.Contains("Phased", html);

        // Reminder banner present
        Assert.Contains("#FFF8E8", html);
        Assert.Contains("&#9888;", html);

        // CTA href = magicLinkUrl (not Summary.RespondUrl)
        Assert.Contains("href=\"https://x/legacy\"", html);
        Assert.Contains("Respond Now", html);
    }

}
