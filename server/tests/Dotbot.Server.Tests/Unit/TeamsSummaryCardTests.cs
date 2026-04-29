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
        string respondUrl = "https://example/respond/abc")
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
        var texts = Body(card)
            .SelectMany(FlattenTextBlocks)
            .Select(b => b.GetProperty("text").GetString())
            .ToList();

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
        var texts = Body(card)
            .SelectMany(FlattenTextBlocks)
            .Select(b => b.GetProperty("text").GetString())
            .ToList();

        Assert.Contains("Two diagrams + ADR", texts);
        Assert.Contains("Sign-off needed", texts);
    }

    [Fact]
    public void BatchQuestions_RenderAsFactSetWithMarkers()
    {
        var card = Render(Summary(batchQuestions: new()
        {
            new() { QuestionId = Guid.NewGuid(), Title = "Q1", Type = "approval", IsAnswered = false },
            new() { QuestionId = Guid.NewGuid(), Title = "Q2", Type = "singleChoice", IsAnswered = true, AnsweredSummary = "A" },
        }));

        var factSet = Body(card).Single(e => e.GetProperty("type").GetString() == "FactSet");
        var facts = factSet.GetProperty("facts").EnumerateArray().ToList();

        Assert.Equal(2, facts.Count);
        Assert.Equal("⏳", facts[0].GetProperty("title").GetString());
        Assert.Equal("Q1 (approval)", facts[0].GetProperty("value").GetString());
        Assert.Equal("✓", facts[1].GetProperty("title").GetString());
        Assert.Equal("Q2 (singleChoice) — A", facts[1].GetProperty("value").GetString());
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

        var texts = Body(card)
            .SelectMany(FlattenTextBlocks)
            .Select(b => b.GetProperty("text").GetString()!)
            .ToList();

        Assert.Contains(texts, t => t == "• spec.pdf (512 KB)");
        Assert.Contains(texts, t => t == "• tiny.txt (256 B)");
        Assert.Contains(texts, t => t == "• unknown.bin");
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
            linkContainers[0].GetProperty("items")[0].GetProperty("text").GetString());

        Assert.Equal("https://example/design",
            linkContainers[1].GetProperty("selectAction").GetProperty("url").GetString());
        Assert.Equal("• Design",
            linkContainers[1].GetProperty("items")[0].GetProperty("text").GetString());
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
    public void Actions_SingleRespondNowOpenUrl()
    {
        var card = Render(Summary(respondUrl: "https://example/respond/xyz"));
        var action = Assert.Single(card.GetProperty("actions").EnumerateArray());

        Assert.Equal("Action.OpenUrl", action.GetProperty("type").GetString());
        Assert.Equal("Respond Now", action.GetProperty("title").GetString());
        Assert.Equal("https://example/respond/xyz", action.GetProperty("url").GetString());
    }

    [Fact]
    public void MinimalSummary_OmitsEmptySections()
    {
        var card = Render(Summary());
        var types = Body(card).Select(e => e.GetProperty("type").GetString()).ToList();

        Assert.DoesNotContain("FactSet", types);
        Assert.Single(card.GetProperty("actions").EnumerateArray());
    }

    private static IEnumerable<JsonElement> FlattenTextBlocks(JsonElement element)
    {
        var type = element.GetProperty("type").GetString();
        if (type == "TextBlock")
        {
            yield return element;
        }
        else if (type == "Container" && element.TryGetProperty("items", out var items))
        {
            foreach (var item in items.EnumerateArray())
                foreach (var inner in FlattenTextBlocks(item))
                    yield return inner;
        }
    }
}
