using Dotbot.Server.Models;
using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

public sealed class InMemoryTemplateStorage : ITemplateStorageService
{
    private readonly List<QuestionTemplate> _saved = [];

    public IReadOnlyList<QuestionTemplate> Saved => _saved;

    public Task ResetAsync()
    {
        _saved.Clear();
        return Task.CompletedTask;
    }

    public Task SaveTemplateAsync(QuestionTemplate template)
    {
        _saved.Add(template);
        return Task.CompletedTask;
    }

    public Task<QuestionTemplate?> GetTemplateAsync(string projectId, Guid questionId, int version)
        => Task.FromResult(_saved.FirstOrDefault(x =>
            x.Project.ProjectId == projectId
            && x.QuestionId == questionId
            && x.Version == version));
}
