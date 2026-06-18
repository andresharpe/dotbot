using System.Text.Json;
using Dotbot.Server.Models;
using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

public sealed class InMemoryTemplateStorage : ITemplateStorageService
{
    private readonly List<QuestionTemplate> _saved = [];
    private readonly Dictionary<string, byte[]> _rawByKey = new();

    public IReadOnlyList<QuestionTemplate> Saved => _saved;

    public Task ResetAsync()
    {
        _saved.Clear();
        _rawByKey.Clear();
        return Task.CompletedTask;
    }

    private static string Key(string projectId, Guid questionId, int version)
        => $"{projectId}/{questionId}/v{version}";

    public Task SaveTemplateAsync(QuestionTemplate template)
    {
        _saved.Add(template);
        return Task.CompletedTask;
    }

    public Task<bool> TrySaveTemplateRawAsync(string projectId, Guid questionId, int version, ReadOnlyMemory<byte> questionJson)
    {
        var key = Key(projectId, questionId, version);
        if (_rawByKey.ContainsKey(key))
            return Task.FromResult(false);

        _rawByKey[key] = questionJson.ToArray();
        var typed = JsonSerializer.Deserialize<QuestionTemplate>(questionJson.Span, JsonSerializerOptions.Web);
        if (typed is not null)
            _saved.Add(typed);
        return Task.FromResult(true);
    }

    public Task<QuestionTemplate?> GetTemplateAsync(string projectId, Guid questionId, int version)
        => Task.FromResult(_saved.FirstOrDefault(x =>
            x.Project.ProjectId == projectId
            && x.QuestionId == questionId
            && x.Version == version));

    public Task<JsonElement?> GetTemplateRawAsync(string projectId, Guid questionId, int version)
    {
        var key = Key(projectId, questionId, version);
        if (_rawByKey.TryGetValue(key, out var bytes))
        {
            using var doc = JsonDocument.Parse(bytes);
            return Task.FromResult<JsonElement?>(doc.RootElement.Clone());
        }

        // Fall back to a template seeded via SaveTemplateAsync.
        var typed = _saved.FirstOrDefault(x =>
            x.Project.ProjectId == projectId && x.QuestionId == questionId && x.Version == version);
        if (typed is null)
            return Task.FromResult<JsonElement?>(null);

        var json = JsonSerializer.SerializeToUtf8Bytes(typed, JsonSerializerOptions.Web);
        using var d2 = JsonDocument.Parse(json);
        return Task.FromResult<JsonElement?>(d2.RootElement.Clone());
    }
}
