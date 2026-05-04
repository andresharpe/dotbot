using System.Text.Json;
using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Tests.Unit;

public class SlackSummaryBlocksTests
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private static NotificationSummary Summary(
        string title = "Approve architecture v2",
        string type = "approval",
        string projectName = "Atlas",
        string? deliverableSummary = null,
        string? context = null,
        List<BatchQuestionRef>? batchQuestions = null,
        List<AttachmentRef>? attachments = null,
        List<ReviewLinkRef>? reviewLinks = null,
        string respondUrl = "https://example/respond/abc",
        bool isReminder = false,
        DateTime? dueBy = null)
        => new()
        {
            QuestionTitle = title,
            QuestionType = type,
            ProjectName = projectName,
            DeliverableSummary = deliverableSummary,
            Context = context,
            BatchQuestions = batchQuestions ?? new List<BatchQuestionRef>(),
            Attachments = attachments ?? new List<AttachmentRef>(),
            ReviewLinks = reviewLinks ?? new List<ReviewLinkRef>(),
            RespondUrl = respondUrl,
            IsReminder = isReminder,
            DueBy = dueBy,
        };

    private static List<JsonElement> Render(NotificationSummary s)
    {
        var blocks = SlackDeliveryProvider.BuildSummaryBlocks(s);
        var json = JsonSerializer.Serialize(blocks, SerializerOptions);
        return JsonDocument.Parse(json).RootElement.EnumerateArray().ToList();
    }

    [Fact]
    public void Header_RendersTitle()
    {
        var blocks = Render(Summary(title: "Approve v2"));
        var header = blocks.Single(b => b.GetProperty("type").GetString() == "header");
        Assert.Equal("Approve v2", header.GetProperty("text").GetProperty("text").GetString());
    }

    [Fact]
    public void ContextBlock_HasProjectAndTypeBadge()
    {
        var blocks = Render(Summary(projectName: "Atlas", type: "approval"));
        var ctx = blocks.First(b => b.GetProperty("type").GetString() == "context");
        var text = ctx.GetProperty("elements")[0].GetProperty("text").GetString()!;

        Assert.Contains(":robot_face: Atlas", text);
        Assert.Contains("`approval`", text);
    }

    [Fact]
    public void DeliverableSummaryAndContext_RenderedAsSections()
    {
        var blocks = Render(Summary(
            deliverableSummary: "Two diagrams + ADR",
            context: "Sign-off needed"));
        var sectionTexts = blocks
            .Where(b => b.GetProperty("type").GetString() == "section")
            .Select(b => b.GetProperty("text").GetProperty("text").GetString()!)
            .ToList();

        Assert.Contains(sectionTexts, t => t.Contains("Two diagrams + ADR"));
        Assert.Contains(sectionTexts, t => t == "Sign-off needed");
    }

    [Fact]
    public void BatchQuestions_RenderWithAnsweredAndPendingMarkers()
    {
        var blocks = Render(Summary(batchQuestions: new()
        {
            new() { QuestionId = Guid.NewGuid(), Title = "Q1", Type = "approval", IsAnswered = false },
            new() { QuestionId = Guid.NewGuid(), Title = "Q2", Type = "singleChoice", IsAnswered = true, AnsweredSummary = "A" },
        }));

        var section = blocks
            .Where(b => b.GetProperty("type").GetString() == "section")
            .Select(b => b.GetProperty("text").GetProperty("text").GetString()!)
            .Single(t => t.Contains("Questions in this batch"));

        Assert.Contains("• Q1 (`approval`)", section);
        Assert.Contains("✓ Q2 (`singleChoice`) — _A_", section);
    }

    [Fact]
    public void Attachments_RenderNameAndFormattedSizeWithoutLink()
    {
        var blocks = Render(Summary(attachments: new()
        {
            new() { Name = "spec.pdf", ContentType = "application/pdf", SizeBytes = 524288 },
            new() { Name = "tiny.txt", ContentType = "text/plain", SizeBytes = 256 },
            new() { Name = "unknown.bin", ContentType = "application/octet-stream", SizeBytes = null },
        }));

        var section = blocks
            .Where(b => b.GetProperty("type").GetString() == "section")
            .Select(b => b.GetProperty("text").GetProperty("text").GetString()!)
            .Single(t => t.Contains("Attachments"));

        Assert.Contains("• spec.pdf (512 KB)", section);
        Assert.Contains("• tiny.txt (256 B)", section);
        Assert.Contains("• unknown.bin", section);
        Assert.DoesNotContain("<http", section);
    }

    [Fact]
    public void ReviewLinks_RenderAsClickableMrkdwnWithRequiresReview()
    {
        var blocks = Render(Summary(reviewLinks: new()
        {
            new() { Title = "ADR-7", Url = "https://example/adr/7", Type = "documentation" },
            new() { Title = "Design", Url = "https://example/design", Type = null },
        }));

        var section = blocks
            .Where(b => b.GetProperty("type").GetString() == "section")
            .Select(b => b.GetProperty("text").GetProperty("text").GetString()!)
            .Single(t => t.Contains("Review links"));

        Assert.Contains("• <https://example/adr/7|ADR-7> _(requires review)_", section);
        Assert.Contains("• <https://example/design|Design>", section);
    }

    [Fact]
    public void ReviewLinks_SkipsMalformedAndNonHttpSchemes()
    {
        var blocks = Render(Summary(reviewLinks: new()
        {
            new() { Title = "Bad", Url = "not a url", Type = null },
            new() { Title = "Spoof", Url = "javascript:alert(1)", Type = null },
            new() { Title = "Data", Url = "data:text/html,<x>", Type = null },
            new() { Title = "Good", Url = "https://example/ok", Type = null },
        }));

        var section = blocks
            .Where(b => b.GetProperty("type").GetString() == "section")
            .Select(b => b.GetProperty("text").GetProperty("text").GetString()!)
            .Single(t => t.Contains("Review links"));

        Assert.Contains("• <https://example/ok|Good>", section);
        Assert.DoesNotContain("Bad", section);
        Assert.DoesNotContain("javascript:", section);
        Assert.DoesNotContain("data:", section);
    }

    [Fact]
    public void Actions_SingleRespondNowButton()
    {
        var blocks = Render(Summary(respondUrl: "https://example/respond/xyz"));
        var actions = blocks.Single(b => b.GetProperty("type").GetString() == "actions");
        var elements = actions.GetProperty("elements").EnumerateArray().ToList();

        var button = Assert.Single(elements);
        Assert.Equal("button", button.GetProperty("type").GetString());
        Assert.Equal("Respond Now", button.GetProperty("text").GetProperty("text").GetString());
        Assert.Equal("https://example/respond/xyz", button.GetProperty("url").GetString());
        Assert.Equal("primary", button.GetProperty("style").GetString());
    }

    [Fact]
    public void Reminder_RendersBannerBeforeHeader()
    {
        var blocks = Render(Summary(isReminder: true));
        var first = blocks[0];

        Assert.Equal("context", first.GetProperty("type").GetString());
        var text = first.GetProperty("elements")[0].GetProperty("text").GetString()!;
        Assert.Contains("Reminder", text);
        Assert.Contains("awaiting your response", text);
    }

    [Fact]
    public void Reminder_OmittedWhenIsReminderFalse()
    {
        var blocks = Render(Summary(isReminder: false));
        Assert.Equal("header", blocks[0].GetProperty("type").GetString());
    }

    [Fact]
    public void DueBy_RendersFormattedUtcContextLine()
    {
        var due = new DateTime(2026, 5, 1, 14, 30, 0, DateTimeKind.Utc);
        var blocks = Render(Summary(dueBy: due));

        var contextTexts = blocks
            .Where(b => b.GetProperty("type").GetString() == "context")
            .Select(b => b.GetProperty("elements")[0].GetProperty("text").GetString()!)
            .ToList();

        Assert.Contains(contextTexts, t => t.Contains("Due by:") && t.Contains("2026-05-01 14:30 UTC"));
    }

    [Fact]
    public void DueBy_TreatsUnspecifiedKindAsUtc()
    {
        // Regression: deserialised DateTimes commonly arrive with Kind=Unspecified.
        // ToUniversalTime on Unspecified treats as Local and shifts by host offset,
        // producing a wrong value labelled "UTC". Helper must short-circuit.
        var unspecified = DateTime.SpecifyKind(new DateTime(2026, 5, 1, 14, 30, 0), DateTimeKind.Unspecified);
        var blocks = Render(Summary(dueBy: unspecified));

        var dueText = blocks
            .Where(b => b.GetProperty("type").GetString() == "context")
            .Select(b => b.GetProperty("elements")[0].GetProperty("text").GetString()!)
            .Single(t => t.Contains("Due by:"));

        Assert.Contains("2026-05-01 14:30 UTC", dueText);
    }

    [Fact]
    public void DueBy_OmittedWhenNull()
    {
        var blocks = Render(Summary(dueBy: null));
        var contextTexts = blocks
            .Where(b => b.GetProperty("type").GetString() == "context")
            .Select(b => b.GetProperty("elements")[0].GetProperty("text").GetString()!)
            .ToList();
        Assert.DoesNotContain(contextTexts, t => t.Contains("Due by"));
    }

    [Fact]
    public void MinimalSummary_OmitsEmptySections()
    {
        var blocks = Render(Summary());
        var types = blocks.Select(b => b.GetProperty("type").GetString()!).ToList();

        Assert.Equal(new[] { "header", "context", "actions" }, types);
    }
}
