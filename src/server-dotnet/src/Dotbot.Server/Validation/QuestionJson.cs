using System.Text.Json;
using System.Text.Json.Nodes;
using Dotbot.Server.Models;

namespace Dotbot.Server.Validation;

// Helpers for the verbatim question JsonElement on the envelope wire.
public static class QuestionJson
{
    public static string? ReadType(JsonElement question) =>
        question.ValueKind == JsonValueKind.Object
        && question.TryGetProperty("type", out var t)
        && t.ValueKind == JsonValueKind.String
            ? t.GetString()
            : null;

    public static int ReadVersion(JsonElement question)
    {
        if (question.ValueKind == JsonValueKind.Object
            && question.TryGetProperty("version", out var v)
            && v.ValueKind == JsonValueKind.Number
            && v.TryGetInt32(out var version))
            return version;
        return 1;
    }

    public static bool TryReadQuestionId(JsonElement question, out Guid questionId)
    {
        questionId = Guid.Empty;
        if (question.ValueKind != JsonValueKind.Object) return false;
        // Accept either questionId (QuestionTemplate field name) or the spec's id.
        foreach (var name in new[] { "questionId", "id" })
            if (question.TryGetProperty(name, out var el) && el.TryGetGuid(out questionId))
                return true;
        return false;
    }

    /// <summary>
    /// Normalizes ONLY the options property per type and returns the question as UTF-8
    /// bytes for storage. Surgical (JsonNode) so every other field - including unknown
    /// forward-compatible ones - survives verbatim (SPEC-029 sec.5.1 vs sec.3.1).
    ///   approval / freeText    -> options forced to [] (type carries the semantics;
    ///                             [] kept rather than removed because QuestionTemplate.Options
    ///                             is a C# `required` member - see SPEC-029 deviations sec.5.1)
    ///   singleChoice / ranking -> options left untouched
    /// </summary>
    public static byte[] NormalizeForStorage(JsonElement question, string? type)
    {
        var node = JsonNode.Parse(question.GetRawText())!.AsObject();

        if (type == QuestionTypes.Approval || type == QuestionTypes.FreeText)
            node["options"] = new JsonArray();

        return JsonSerializer.SerializeToUtf8Bytes(node);
    }
}
