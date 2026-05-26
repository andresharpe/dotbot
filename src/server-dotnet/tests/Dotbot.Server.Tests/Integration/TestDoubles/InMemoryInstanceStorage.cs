using Dotbot.Server.Models;
using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

/// <summary>
/// In-memory <see cref="IInstanceStorageService"/> for integration tests.
/// Stores <see cref="QuestionInstance"/> by (projectId, instanceId) so middleware /
/// dashboard ownership lookups resolve without hitting Azurite.
/// </summary>
public sealed class InMemoryInstanceStorage : IInstanceStorageService
{
    private readonly Dictionary<(string ProjectId, Guid InstanceId), QuestionInstance> _store = new();

    public IReadOnlyDictionary<(string ProjectId, Guid InstanceId), QuestionInstance> Saved => _store;

    public Task ResetAsync()
    {
        _store.Clear();
        return Task.CompletedTask;
    }

    public Task SaveInstanceAsync(QuestionInstance instance)
    {
        _store[(instance.ProjectId, instance.InstanceId)] = instance;
        return Task.CompletedTask;
    }

    public Task<QuestionInstance?> GetInstanceAsync(string projectId, Guid instanceId)
        => Task.FromResult(_store.TryGetValue((projectId, instanceId), out var v) ? v : null);

    public async IAsyncEnumerable<QuestionInstance> ListActiveInstancesAsync()
    {
        foreach (var i in _store.Values)
            if (i.OverallStatus == "active")
                yield return i;
        await Task.CompletedTask;
    }

    public async IAsyncEnumerable<QuestionInstance> ListAllInstancesAsync()
    {
        foreach (var i in _store.Values)
            yield return i;
        await Task.CompletedTask;
    }

    public Task<bool> DeleteInstanceAsync(string projectId, Guid instanceId)
        => Task.FromResult(_store.Remove((projectId, instanceId)));
}
