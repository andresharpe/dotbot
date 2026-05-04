using System.Text.Json;
using Dotbot.Server.Services;
using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Tests.Unit;

public class TeamsSummaryCardTests
{
    private static readonly AdaptiveCardService Service = new();

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

    private static JsonElement Render(NotificationSummary s) =>
        JsonDocument.Parse(Service.CreateSummaryCard(s).ToJson()).RootElement;

    private static IEnumerable<JsonElement> Body(JsonElement card) =>
        card.GetProperty("body").EnumerateArray();

    [Fact]
    public void Card_IsAdaptiveCard_v15()
    {
        var card = Render(Summary());
        Assert.Equal("AdaptiveCard", card.GetProperty("type").GetString());
        Assert.Equal("1.5", card.GetProperty("version").GetString());
    }

    [Fact]
    public void Header_RendersProjectTitleAndTypeBadge()
    {
        var card = Render(Summary(title: "Approve v2", type: "approval", projectName: "Atlas"));
        var texts = AllTexts(card);

        Assert.Contains("Atlas", texts);
        Assert.Contains("Approve v2", texts);
        Assert.Contains("Type: approval", texts);
    }

    [Fact]
    public void DeliverableSummaryAndContext_RenderedWhenSet()
    {
        var card = Render(Summary(
            deliverableSummary: "Two diagrams + ADR",
            context: "Sign-off needed"));
        var texts = AllTexts(card);

        Assert.Contains("Two diagrams + ADR", texts);
        Assert.Contains("Sign-off needed", texts);
    }

    [Fact]
    public void BatchQuestions_RenderEachAsRichTextBlockWithMarker()
    {
        var card = Render(Summary(batchQuestions: new()
        {
            new() { QuestionId = Guid.NewGuid(), Title = "Q1", Type = "approval", IsAnswered = false },
            new() { QuestionId = Guid.NewGuid(), Title = "Q2", Type = "singleChoice", IsAnswered = true, AnsweredSummary = "A" },
        }));

        var texts = AllTexts(card);

        Assert.Contains("⏳ Q1 (approval)", texts);
        Assert.Contains("✓ Q2 (singleChoice) — A", texts);
    }

    [Fact]
    public void Attachments_RenderNameAndFormattedSizeWithoutLink()
    {
        var card = Render(Summary(attachments: new()
        {
            new() { Name = "spec.pdf", ContentType = "application/pdf", SizeBytes = 524288 },
            new() { Name = "tiny.txt", ContentType = "text/plain", SizeBytes = 256 },
            new() { Name = "unknown.bin", ContentType = "application/octet-stream", SizeBytes = null },
        }));

        var texts = AllTexts(card);

        Assert.Contains("• spec.pdf (512 KB)", texts);
        Assert.Contains("• tiny.txt (256 B)", texts);
        Assert.Contains("• unknown.bin (—)", texts);
        Assert.DoesNotContain(texts, t => t.Contains("http") && t.Contains("spec.pdf"));
    }

    [Fact]
    public void ReviewLinks_RenderAsContainerWithSelectActionAndRequiresReviewMarker()
    {
        var card = Render(Summary(reviewLinks: new()
        {
            new() { Title = "ADR-7", Url = "https://example/adr/7", Type = "documentation" },
            new() { Title = "Design", Url = "https://example/design", Type = null },
        }));

        var linkContainers = Body(card)
            .Where(e => e.GetProperty("type").GetString() == "Container"
                && e.TryGetProperty("selectAction", out var sa)
                && sa.GetProperty("type").GetString() == "Action.OpenUrl")
            .ToList();

        Assert.Equal(2, linkContainers.Count);

        Assert.Equal("https://example/adr/7",
            linkContainers[0].GetProperty("selectAction").GetProperty("url").GetString());
        Assert.Equal("• ADR-7 (requires review)",
            ConcatRichTextBlock(linkContainers[0].GetProperty("items")[0]));

        Assert.Equal("https://example/design",
            linkContainers[1].GetProperty("selectAction").GetProperty("url").GetString());
        Assert.Equal("• Design",
            ConcatRichTextBlock(linkContainers[1].GetProperty("items")[0]));
    }

    [Fact]
    public void UntrustedFields_RenderedAsRichTextBlock_NotMarkdown()
    {
        // RichTextBlock + TextRun ensures untrusted DTO strings cannot inject markdown
        // hyperlinks like [click](evil) into the card.
        var card = Render(Summary(
            title: "[click me](https://evil.example)",
            projectName: "**bold**",
            deliverableSummary: "[exfil](https://evil)"));

        var richTextBlocks = Body(card)
            .Where(e => e.GetProperty("type").GetString() == "RichTextBlock")
            .ToList();

        Assert.NotEmpty(richTextBlocks);
        // No TextBlock should carry the raw untrusted strings (markdown surface)
        var textBlocks = Body(card)
            .Where(e => e.GetProperty("type").GetString() == "TextBlock")
            .Select(e => e.GetProperty("text").GetString())
            .ToList();
        Assert.DoesNotContain(textBlocks, t => t!.Contains("[click me]"));
        Assert.DoesNotContain(textBlocks, t => t!.Contains("**bold**"));
        Assert.DoesNotContain(textBlocks, t => t!.Contains("[exfil]"));
    }

    [Fact]
    public void ReviewLinks_SkipsEntriesWithMalformedUrl()
    {
        var card = Render(Summary(reviewLinks: new()
        {
            new() { Title = "Bad", Url = "not a url", Type = null },
            new() { Title = "Good", Url = "https://example/ok", Type = null },
        }));

        var linkContainers = Body(card)
            .Where(e => e.GetProperty("type").GetString() == "Container"
                && e.TryGetProperty("selectAction", out _))
            .ToList();

        Assert.Single(linkContainers);
        Assert.Equal("https://example/ok",
            linkContainers[0].GetProperty("selectAction").GetProperty("url").GetString());
    }

    [Fact]
    public void ReviewLinks_SkipsNonHttpSchemes()
    {
        var card = Render(Summary(reviewLinks: new()
        {
            new() { Title = "Spoof", Url = "javascript:alert(1)", Type = null },
            new() { Title = "Data", Url = "data:text/html,<x>", Type = null },
            new() { Title = "Good", Url = "https://example/ok", Type = null },
        }));

        var linkContainers = Body(card)
            .Where(e => e.GetProperty("type").GetString() == "Container"
                && e.TryGetProperty("selectAction", out _))
            .ToList();

        Assert.Single(linkContainers);
        Assert.Equal("https://example/ok",
            linkContainers[0].GetProperty("selectAction").GetProperty("url").GetString());
    }

    [Fact]
    public void Actions_SingleRespondNowOpenUrl()
    {
        var card = Render(Summary(respondUrl: "https://example/respond/xyz"));
        var action = Assert.Single(card.GetProperty("actions").EnumerateArray());

        Assert.Equal("Action.OpenUrl", action.GetProperty("type").GetString());
        Assert.Equal("Respond Now", action.GetProperty("title").GetString());
        Assert.Equal("https://example/respond/xyz", action.GetProperty("url").GetString());
    }

    [Fact]
    public void Reminder_RendersWarningContainerBeforeProjectBanner()
    {
        var card = Render(Summary(isReminder: true, projectName: "Atlas"));
        var bodyArr = Body(card).ToList();

        // First element must be a warning-styled container with the reminder text
        var first = bodyArr[0];
        Assert.Equal("Container", first.GetProperty("type").GetString());
        Assert.Equal("warning", first.GetProperty("style").GetString());
        var firstText = ConcatRichTextBlock(first.GetProperty("items")[0]);
        Assert.Contains("Reminder", firstText);
        Assert.Contains("awaiting your response", firstText);
    }

    [Fact]
    public void Reminder_OmittedWhenIsReminderFalse()
    {
        var card = Render(Summary(isReminder: false));
        var styles = Body(card)
            .Where(e => e.GetProperty("type").GetString() == "Container"
                && e.TryGetProperty("style", out _))
            .Select(e => e.GetProperty("style").GetString())
            .ToList();
        Assert.DoesNotContain("warning", styles);
    }

    [Fact]
    public void DueBy_RendersFormattedUtcLine()
    {
        var due = new DateTime(2026, 5, 1, 14, 30, 0, DateTimeKind.Utc);
        var card = Render(Summary(dueBy: due));
        var texts = AllTexts(card);

        Assert.Contains(texts, t => t.Contains("Due by:") && t.Contains("2026-05-01 14:30 UTC"));
    }

    [Fact]
    public void DueBy_OmittedWhenNull()
    {
        var card = Render(Summary(dueBy: null));
        var texts = AllTexts(card);
        Assert.DoesNotContain(texts, t => t.Contains("Due by"));
    }

    [Fact]
    public void MinimalSummary_OmitsEmptySections()
    {
        var card = Render(Summary());
        var types = Body(card).Select(e => e.GetProperty("type").GetString()).ToList();

        Assert.DoesNotContain("FactSet", types);
        Assert.Single(card.GetProperty("actions").EnumerateArray());
    }

    private static List<string> AllTexts(JsonElement card) =>
        Body(card).SelectMany(FlattenTextElements)
            .Select(e => e.GetProperty("type").GetString() == "RichTextBlock"
                ? ConcatRichTextBlock(e)
                : e.GetProperty("text").GetString() ?? "")
            .ToList();

    private static string ConcatRichTextBlock(JsonElement richTextBlock) =>
        string.Concat(richTextBlock.GetProperty("inlines").EnumerateArray()
            .Select(r => r.GetProperty("text").GetString() ?? ""));

    private static IEnumerable<JsonElement> FlattenTextElements(JsonElement element)
    {
        var type = element.GetProperty("type").GetString();
        if (type is "TextBlock" or "RichTextBlock")
        {
            yield return element;
        }
        else if (type == "Container" && element.TryGetProperty("items", out var items))
        {
            foreach (var item in items.EnumerateArray())
                foreach (var inner in FlattenTextElements(item))
                    yield return inner;
        }
    }
}
