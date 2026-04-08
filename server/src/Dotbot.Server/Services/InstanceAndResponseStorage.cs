using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Dotbot.Server.Models;
using System.Text.Json;

namespace Dotbot.Server.Services;

public class AttachmentStorageService
{
    private readonly BlobContainerClient _container;
    private readonly StoragePathResolver _paths;

    public AttachmentStorageService(BlobServiceClient blob, StoragePathResolver paths)
    {
        _container = blob.GetBlobContainerClient("answers");
        _paths = paths;
    }

    public async Task<AttachmentRecord> SaveAsync(Guid responseId, string fileName, Stream content, long sizeBytes)
    {
        var blobPath = _paths.AttachmentBlobPath(responseId, fileName);
        var blob = _container.GetBlobClient(blobPath);
        await blob.UploadAsync(content, overwrite: true);
        return new AttachmentRecord { Name = fileName, SizeBytes = sizeBytes, BlobPath = blobPath };
    }

    public async Task<(Stream Content, string ContentType)?> DownloadAsync(string blobPath)
    {
        try
        {
            var blob = _container.GetBlobClient(blobPath);
            var result = await blob.DownloadStreamingAsync();
            var contentType = result.Value.Details.ContentType ?? "application/octet-stream";
            return (result.Value.Content, contentType);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }
}

public class InstanceStorageService
{
    private readonly BlobContainerClient _container;
    private readonly StoragePathResolver _paths;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public InstanceStorageService(BlobServiceClient blob, StoragePathResolver paths)
    {
        _container = blob.GetBlobContainerClient("answers");
        _paths = paths;
    }

    public async Task SaveInstanceAsync(QuestionInstance instance)
    {
        var path = _paths.InstancePath(instance.ProjectId, instance.InstanceId);
        var blob = _container.GetBlobClient(path);
        var json = JsonSerializer.Serialize(instance, JsonOptions);
        await blob.UploadAsync(BinaryData.FromString(json), overwrite: true);
    }

    public async Task<QuestionInstance?> GetInstanceAsync(string projectId, Guid instanceId)
    {
        try
        {
            var path = _paths.InstancePath(projectId, instanceId);
            var blob = _container.GetBlobClient(path);
            var content = await blob.DownloadContentAsync();
            return JsonSerializer.Deserialize<QuestionInstance>(content.Value.Content.ToString(), JsonOptions);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    /// <summary>
    /// Enumerates all active instances across all projects.
    /// Scans blobs under {env}/projects/*/instances/*.json and filters by OverallStatus == "active".
    /// </summary>
    public async IAsyncEnumerable<QuestionInstance> ListActiveInstancesAsync()
    {
        var prefix = _paths.InstancesGlobPrefix();
        await foreach (BlobItem item in _container.GetBlobsAsync(prefix: prefix))
        {
            if (!IsInstanceBlobPath(item.Name))
                continue;

            QuestionInstance? instance = null;
            try
            {
                var blob = _container.GetBlobClient(item.Name);
                var content = await blob.DownloadContentAsync();
                instance = JsonSerializer.Deserialize<QuestionInstance>(content.Value.Content.ToString(), JsonOptions);
            }
            catch (RequestFailedException ex) when (ex.Status == 404)
            {
                continue;
            }

            if (instance is not null && instance.OverallStatus == "active")
                yield return instance;
        }
    }

    public async Task<bool> DeleteInstanceAsync(string projectId, Guid instanceId)
    {
        try
        {
            var path = _paths.InstancePath(projectId, instanceId);
            var blob = _container.GetBlobClient(path);
            var response = await blob.DeleteIfExistsAsync();
            return response.Value;
        }
        catch (RequestFailedException)
        {
            return false;
        }
    }

    /// <summary>
    /// Enumerates all instances across all projects regardless of status.
    /// </summary>
    public async IAsyncEnumerable<QuestionInstance> ListAllInstancesAsync()
    {
        var prefix = _paths.InstancesGlobPrefix();
        await foreach (BlobItem item in _container.GetBlobsAsync(prefix: prefix))
        {
            if (!IsInstanceBlobPath(item.Name))
                continue;

            QuestionInstance? instance = null;
            try
            {
                var blob = _container.GetBlobClient(item.Name);
                var content = await blob.DownloadContentAsync();
                instance = JsonSerializer.Deserialize<QuestionInstance>(content.Value.Content.ToString(), JsonOptions);
            }
            catch (RequestFailedException ex) when (ex.Status == 404)
            {
                continue;
            }

            if (instance is not null)
                yield return instance;
        }
    }

    /// <summary>
    /// Returns true only for instance blobs ({env}/projects/{pid}/instances/{iid}.json),
    /// excluding response blobs whose paths also contain "/instances/".
    /// </summary>
    private static bool IsInstanceBlobPath(string blobName)
    {
        if (!blobName.EndsWith(".json") || !blobName.Contains("/instances/"))
            return false;

        // Response blobs contain "/responses/" — exclude them
        if (blobName.Contains("/responses/"))
            return false;

        // Instance path: {env}/projects/{pid}/instances/{iid}.json
        // Response path: {env}/projects/{pid}/questions/{qid}/instances/{iid}/responses/{rid}.json
        // Template path: {env}/projects/{pid}/questions/{qid}/v{ver}.json (no /instances/, already excluded)
        return true;
    }
}

public class ResponseStorageService
{
    private readonly BlobContainerClient _container;
    private readonly StoragePathResolver _paths;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public ResponseStorageService(BlobServiceClient blob, StoragePathResolver paths)
    {
        _container = blob.GetBlobContainerClient("answers");
        _paths = paths;
    }

    public async Task SaveResponseAsync(ResponseRecordV2 response)
    {
        var path = _paths.ResponsePath(response.ProjectId, response.QuestionId, response.InstanceId, response.ResponseId);
        var blob = _container.GetBlobClient(path);
        var json = JsonSerializer.Serialize(response, JsonOptions);
        await blob.UploadAsync(BinaryData.FromString(json), overwrite: true);
    }

    public async IAsyncEnumerable<ResponseRecordV2> ListResponsesAsync(string projectId, Guid questionId, Guid instanceId)
    {
        var prefix = _paths.ResponsesPrefix(projectId, questionId, instanceId);
        await foreach (BlobItem item in _container.GetBlobsAsync(prefix: prefix))
        {
            var blob = _container.GetBlobClient(item.Name);
            var content = await blob.DownloadContentAsync();
            var record = JsonSerializer.Deserialize<ResponseRecordV2>(content.Value.Content.ToString(), JsonOptions);
            if (record is not null) yield return record;
        }
    }

    /// <summary>
    /// Lists all responses for a question across all instance IDs.
    /// Used by the dashboard to find responses that may be stored under different instance IDs.
    /// </summary>
    public async IAsyncEnumerable<ResponseRecordV2> ListResponsesForQuestionAsync(string projectId, Guid questionId)
    {
        var prefix = _paths.ResponsesForQuestionPrefix(projectId, questionId);
        await foreach (BlobItem item in _container.GetBlobsAsync(prefix: prefix))
        {
            if (!item.Name.Contains("/responses/")) continue;
            var blob = _container.GetBlobClient(item.Name);
            var content = await blob.DownloadContentAsync();
            var record = JsonSerializer.Deserialize<ResponseRecordV2>(content.Value.Content.ToString(), JsonOptions);
            if (record is not null) yield return record;
        }
    }

    public async Task<int> DeleteResponsesForInstanceAsync(string projectId, Guid questionId, Guid instanceId)
    {
        var prefix = _paths.ResponsesPrefix(projectId, questionId, instanceId);
        var count = 0;
        await foreach (BlobItem item in _container.GetBlobsAsync(prefix: prefix))
        {
            var blob = _container.GetBlobClient(item.Name);
            await blob.DeleteIfExistsAsync();
            count++;
        }
        return count;
    }
}
