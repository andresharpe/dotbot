using System.Text.Json;
using Dotbot.Server.Models;
using Dotbot.Server.Models.Envelope;
using Dotbot.Server.Validation;

namespace Dotbot.Server.Tests.Unit;

public class EnvelopeContractTests
{
    private static readonly JsonSerializerOptions Web = JsonSerializerOptions.Web;

    // ── QuestionJson.NormalizeForStorage ───────────────────────────────────────

    [Theory]
    [InlineData(QuestionTypes.Approval)]
    [InlineData(QuestionTypes.FreeText)]
    public void Normalize_ForcesOptionsEmpty_ForApprovalAndFreeText(string type)
    {
        var question = JsonSerializer.Deserialize<JsonElement>(
            $$"""{ "questionId": "{{Guid.NewGuid()}}", "type": "{{type}}", "options": [ { "key": "x" } ], "extraField": 42 }""");

        var bytes = QuestionJson.NormalizeForStorage(question, type);
        using var doc = JsonDocument.Parse(bytes);

        Assert.Equal(JsonValueKind.Array, doc.RootElement.GetProperty("options").ValueKind);
        Assert.Equal(0, doc.RootElement.GetProperty("options").GetArrayLength());
        // Unknown forward-compat field survives the surgical edit.
        Assert.Equal(42, doc.RootElement.GetProperty("extraField").GetInt32());
    }

    [Fact]
    public void Normalize_LeavesOptionsUntouched_ForSingleChoice()
    {
        var question = JsonSerializer.Deserialize<JsonElement>(
            """{ "type": "singleChoice", "options": [ { "key": "a" }, { "key": "b" } ] }""");

        var bytes = QuestionJson.NormalizeForStorage(question, QuestionTypes.SingleChoice);
        using var doc = JsonDocument.Parse(bytes);

        Assert.Equal(2, doc.RootElement.GetProperty("options").GetArrayLength());
    }

    [Fact]
    public void TryReadQuestionId_AcceptsQuestionIdOrId()
    {
        var byQuestionId = JsonSerializer.Deserialize<JsonElement>($$"""{ "questionId": "{{Guid.NewGuid()}}" }""");
        var byId = JsonSerializer.Deserialize<JsonElement>($$"""{ "id": "{{Guid.NewGuid()}}" }""");

        Assert.True(QuestionJson.TryReadQuestionId(byQuestionId, out var a));
        Assert.NotEqual(Guid.Empty, a);
        Assert.True(QuestionJson.TryReadQuestionId(byId, out var b));
        Assert.NotEqual(Guid.Empty, b);
    }

    // ── Timestamps ─────────────────────────────────────────────────────────────

    [Theory]
    [InlineData("2026-05-21T11:54:32Z")]
    [InlineData("2026-05-21T11:54:32+02:00")]
    public void Timestamps_AcceptsExplicitTimezone(string value)
    {
        Assert.True(Timestamps.TryParseUtc(value, out var utc));
        Assert.Equal(DateTimeKind.Utc, utc.Kind);
    }

    [Theory]
    [InlineData("2026-05-21T11:54:32")]   // no timezone designator
    [InlineData("not a date")]
    [InlineData("")]
    [InlineData(null)]
    public void Timestamps_RejectsLocalOrJunk(string? value)
    {
        Assert.False(Timestamps.TryParseUtc(value, out _));
    }

    [Fact]
    public void Timestamps_FormatUtc_EmitsZSuffix()
    {
        var formatted = Timestamps.FormatUtc(new DateTime(2026, 5, 21, 11, 54, 32, DateTimeKind.Utc));
        Assert.Equal("2026-05-21T11:54:32Z", formatted);
    }

    // ── ResponseRecordV2 round-trip ─────────────────────────────────────────────

    [Fact]
    public void ResponseRecordV2_RoundTrips_AsFlatStorageRecord()
    {
        var original = new ResponseRecordV2
        {
            ResponseId = Guid.NewGuid(),
            InstanceId = Guid.NewGuid(),
            QuestionId = Guid.NewGuid(),
            ProjectId = "proj-1",
            SubmittedAt = new DateTime(2026, 5, 21, 9, 38, 11, DateTimeKind.Utc),
            AnsweredVia = "outpost",
            ApprovalDecision = "approved",
            Comment = "ok",
            ResponderEmail = "r@example.com",
        };

        var json = JsonSerializer.Serialize(original, Web);
        var back = JsonSerializer.Deserialize<ResponseRecordV2>(json, Web)!;

        Assert.Equal(original.ResponseId, back.ResponseId);
        Assert.Equal("approved", back.ApprovalDecision);
        Assert.Equal("ok", back.Comment);
        Assert.Equal("r@example.com", back.ResponderEmail);
        // The blob is decoupled from the wire: no question, no nested answer/responder
        // sections, and no wire-only status field.
        Assert.DoesNotContain("\"question\"", json);
        Assert.DoesNotContain("\"answer\"", json);
        Assert.DoesNotContain("\"status\"", json);
    }

    [Fact]
    public void Envelope_AgreesWithFirst_OmittedWhenNull()
    {
        var msg = new EnvelopeMessage { Envelope = new EnvelopeDto { OutpostInstanceId = Guid.NewGuid() } };
        var json = JsonSerializer.Serialize(msg, Web);
        Assert.DoesNotContain("agreesWithFirst", json);
    }
}
