using Azure;
using Azure.Storage.Blobs;
using Dotbot.Server.Models;
using System.Text.Json;

namespace Dotbot.Server.Services;

public class TemplateStorageService : ITemplateStorageService
{
    private readonly BlobContainerClient _container;
    private readonly StoragePathResolver _paths;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public TemplateStorageService(BlobServiceClient blob, StoragePathResolver paths)
    {
        _container = blob.GetBlobContainerClient("answers");
        _paths = paths;
    }

    public async Task SaveTemplateAsync(QuestionTemplate template)
    {
        var path = _paths.TemplatePath(template.Project.ProjectId, template.QuestionId, template.Version);
        var blob = _container.GetBlobClient(path);
        var json = JsonSerializer.Serialize(template, JsonOptions);
        await blob.UploadAsync(BinaryData.FromString(json), overwrite: true);
    }

    public async Task<bool> TrySaveTemplateRawAsync(string projectId, Guid questionId, int version, ReadOnlyMemory<byte> questionJson)
    {
        var path = _paths.TemplatePath(projectId, questionId, version);
        var blob = _container.GetBlobClient(path);
        try
        {
            await blob.UploadAsync(BinaryData.FromBytes(questionJson), overwrite: false);
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status == 409)
        {
            // Immutability (SPEC-029 sec.3.1/6.1): a template already exists for this key.
            return false;
        }
    }

    public async Task<QuestionTemplate?> GetTemplateAsync(string projectId, Guid questionId, int version)
    {
        try
        {
            var path = _paths.TemplatePath(projectId, questionId, version);
            var blob = _container.GetBlobClient(path);
            var content = await blob.DownloadContentAsync();
            return JsonSerializer.Deserialize<QuestionTemplate>(content.Value.Content.ToString(), JsonOptions);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public async Task<JsonElement?> GetTemplateRawAsync(string projectId, Guid questionId, int version)
    {
        try
        {
            var path = _paths.TemplatePath(projectId, questionId, version);
            var blob = _container.GetBlobClient(path);
            var content = await blob.DownloadContentAsync();
            using var doc = JsonDocument.Parse(content.Value.Content.ToString());
            return doc.RootElement.Clone();
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }
}
