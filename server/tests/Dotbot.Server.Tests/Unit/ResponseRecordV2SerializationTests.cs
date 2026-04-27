using System.Text.Json;
using Dotbot.Server.Models;

namespace Dotbot.Server.Tests.Unit;

public class ResponseRecordV2SerializationTests
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
          "responseId": "22222222-2222-2222-2222-222222222222",
          "instanceId": "33333333-3333-3333-3333-333333333333",
          "questionId": "11111111-1111-1111-1111-111111111111",
          "questionVersion": 1,
          "projectId": "p1",
          "selectedKey": "A",
          "freeText": "notes",
          "status": "submitted"
        }
        """;

        var back = JsonSerializer.Deserialize<ResponseRecordV2>(legacyJson, Options)!;

        Assert.Equal("A", back.SelectedKey);
        Assert.Equal("notes", back.FreeText);
        Assert.Null(back.ApprovalDecision);
        Assert.Null(back.Comment);
        Assert.Null(back.ReviewedAttachmentIds);
        Assert.Null(back.RankedItems);
    }
}
