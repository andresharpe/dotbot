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
}
