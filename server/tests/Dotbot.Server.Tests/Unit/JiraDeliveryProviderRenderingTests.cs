using Dotbot.Server.Models;
using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Tests.Unit;

public class JiraDeliveryProviderRenderingTests
{
    private const string DefaultRespondUrl = "https://example/respond/abc";

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

    private static string Normalize(string s) => s.Replace("\r\n", "\n");

    [Fact]
    public void Summary_FullPayload_RendersExpectedWiki()
    {
        var actual = Normalize(JiraDeliveryProvider.BuildJiraCommentFromSummary(MakeFullSummary()));

        const string expected =
            "h3. Approve architecture v2\n" +
            "\n" +
            "*Project:* Project One | *Type:* approval\n" +
            "\n" +
            "Sign-off needed on the v2 architecture proposal.\n" +
            "\n" +
            "_We are choosing between two patterns; a third is out due to cost._\n" +
            "\n" +
            "*Questions in this batch:*\n" +
            "* ✓ Pick the migration strategy _(approval)_ — Approved\n" +
            "* Confirm rollback window _(freeText)_\n" +
            "\n" +
            "*Attachments:*\n" +
            "* diagram.pdf _(239.9 KB)_\n" +
            "* spec.docx _(—)_\n" +
            "\n" +
            "*Review links:*\n" +
            "* [Confluence design doc|https://example.atlassian.net/wiki/x]\n" +
            "\n" +
            "*Due by:* 2026-05-01 17:00 UTC\n" +
            "\n" +
            "[Respond Now|https://example/respond/abc]\n";

        Assert.Equal(expected, actual);
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

        var actual = Normalize(JiraDeliveryProvider.BuildJiraCommentFromSummary(s));

        const string expected =
            "h3. Approve architecture v2\n" +
            "\n" +
            "*Project:* Project One | *Type:* approval\n" +
            "\n" +
            "*Questions in this batch:*\n" +
            "* ✓ Pick the migration strategy _(approval)_ — Approved\n" +
            "* Confirm rollback window _(freeText)_\n" +
            "\n" +
            "[Respond Now|https://example/respond/abc]\n";

        Assert.Equal(expected, actual);
    }

    [Fact]
    public void Summary_IsReminderTrue_PrependsReminderPanel()
    {
        var s = MakeFullSummary();
        s.IsReminder = true;

        var actual = Normalize(JiraDeliveryProvider.BuildJiraCommentFromSummary(s));

        Assert.StartsWith("{panel:borderColor=#f0ad4e|bgColor=#fff4ce}*Reminder:* This question is still awaiting a response.{panel}\nh3. Approve architecture v2\n", actual);
        Assert.EndsWith("[Respond Now|https://example/respond/abc]\n", actual);
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

        var actual = Normalize(JiraDeliveryProvider.BuildJiraComment(template, "https://x/legacy", isReminder: false));

        const string expected =
            "h3. Pick a deployment strategy\n" +
            "\n" +
            "_Trading off speed against safety._\n" +
            "\n" +
            "||Option||Description||\n" +
            "|*A.* Big-bang|Fast but risky|\n" +
            "|*B.* Phased|Slow but safe|\n" +
            "\n" +
            "[Respond Now|https://x/legacy]\n";

        Assert.Equal(expected, actual);
    }

}
