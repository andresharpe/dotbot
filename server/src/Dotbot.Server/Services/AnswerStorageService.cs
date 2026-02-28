using Azure.Storage.Blobs;
using Dotbot.Server.Models;
using System.Text.Json;

namespace Dotbot.Server.Services;

/// <summary>
/// Stores question answers as JSON blobs in the "answers" container.
/// Compatible with dotbot-v3 JSON state patterns.
/// </summary>
public class AnswerStorageService
{
    private readonly BlobContainerClient _container;
    private readonly ILogger<AnswerStorageService> _logger;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public AnswerStorageService(
        BlobServiceClient blobServiceClient,
        ILogger<AnswerStorageService> logger)
    {
        _container = blobServiceClient.GetBlobContainerClient("answers");
        _logger = logger;
    }

    public async Task SaveAnswerAsync(AnswerRecord answer)
    {
        try
        {
            var client = _container.GetBlobClient($"{answer.QuestionId}.json");
            var json = JsonSerializer.Serialize(answer, JsonOptions);
            await client.UploadAsync(BinaryData.FromString(json), overwrite: true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to save answer for question {QuestionId}", answer.QuestionId);
            throw;
        }
    }

    public async Task<AnswerRecord?> GetAnswerAsync(string questionId)
    {
        try
        {
            var client = _container.GetBlobClient($"{questionId}.json");
            var response = await client.DownloadContentAsync();
            return JsonSerializer.Deserialize<AnswerRecord>(
                response.Value.Content.ToString(), JsonOptions);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to read answer for question {QuestionId}", questionId);
            throw;
        }
    }
}
