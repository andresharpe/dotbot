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
