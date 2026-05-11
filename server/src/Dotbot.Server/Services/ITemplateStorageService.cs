using Dotbot.Server.Models;

namespace Dotbot.Server.Services;

public interface ITemplateStorageService
{
    Task SaveTemplateAsync(QuestionTemplate template);
    Task<QuestionTemplate?> GetTemplateAsync(string projectId, Guid questionId, int version);
}
