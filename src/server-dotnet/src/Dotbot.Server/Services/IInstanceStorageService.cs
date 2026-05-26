using Dotbot.Server.Models;

namespace Dotbot.Server.Services;

public interface IInstanceStorageService
{
    Task SaveInstanceAsync(QuestionInstance instance);
    Task<QuestionInstance?> GetInstanceAsync(string projectId, Guid instanceId);
    IAsyncEnumerable<QuestionInstance> ListActiveInstancesAsync();
    IAsyncEnumerable<QuestionInstance> ListAllInstancesAsync();
    Task<bool> DeleteInstanceAsync(string projectId, Guid instanceId);
}
