using System.Text.Json;
using Dotbot.Server.Models;

namespace Dotbot.Server.Tests.Unit;

public class QuestionTemplateSerializationTests
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    [Fact]
    public void Deserialize_EmptyObject_ThrowsJsonExceptionForRequiredProperties()
    {
        // Regression guard: QuestionTemplate has `required` modifiers on QuestionId,
        // Version, Title, Options, Project. Missing any of these causes
        // System.Text.Json to throw JsonException (not return null). The
        // /api/templates endpoint must catch this and return 400, not 500.
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<QuestionTemplate>("{}", Options));
    }

    [Fact]
    public void Deserialize_LegacyPayloadWithoutNewFields_LeavesThemNull()
    {
        const string legacyJson = """
        {
          "questionId": "11111111-1111-1111-1111-111111111111",
          "version": 1,
          "type": "singleChoice",
          "title": "pick one",
          "options": [],
          "project": { "projectId": "p1" },
          "status": "published"
        }
        """;

        var back = JsonSerializer.Deserialize<QuestionTemplate>(legacyJson, Options)!;

        Assert.Equal("singleChoice", back.Type);
        Assert.Equal("pick one", back.Title);
        Assert.Null(back.Attachments);
        Assert.Null(back.ReferenceLinks);
        Assert.Null(back.DeliverableSummary);
    }
}
