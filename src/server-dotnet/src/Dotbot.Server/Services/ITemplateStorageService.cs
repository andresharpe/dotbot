using System.Text.Json;
using Dotbot.Server.Models;

namespace Dotbot.Server.Services;

public interface ITemplateStorageService
{
    // Convenience for tests/seeding - serializes the typed template and overwrites.
    Task SaveTemplateAsync(QuestionTemplate template);

    // Immutable publish: stores the verbatim question JSON bytes with overwrite:false.
    // Returns false when a blob already exists for (projectId, questionId, version)
    // so the endpoint can emit 409 template_exists.
    Task<bool> TrySaveTemplateRawAsync(string projectId, Guid questionId, int version, ReadOnlyMemory<byte> questionJson);

    // Typed read for internal consumers (delivery, dashboard, reminders, web form).
    Task<QuestionTemplate?> GetTemplateAsync(string projectId, Guid questionId, int version);

    // Verbatim read for the envelope assembler - the published question JSON as-is.
    Task<JsonElement?> GetTemplateRawAsync(string projectId, Guid questionId, int version);
}
