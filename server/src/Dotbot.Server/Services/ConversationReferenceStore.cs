using Azure.Storage.Blobs;
using Microsoft.Agents.Core.Models;
using System.Collections.Concurrent;
using System.Text.Json;

namespace Dotbot.Server.Services;

/// <summary>
/// Stores conversation references in Azure Blob Storage with an in-memory cache.
/// Blobs are keyed by user AAD object ID in the "conversation-references" container.
/// </summary>
public class ConversationReferenceStore : IConversationReferenceStore
{
    private readonly BlobContainerClient _container;
    private readonly ILogger<ConversationReferenceStore> _logger;
    private readonly ConcurrentDictionary<string, ConversationReference> _cache = new();
    private bool _cacheLoaded;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public ConversationReferenceStore(
        BlobServiceClient blobServiceClient,
        ILogger<ConversationReferenceStore> logger)
    {
        _container = blobServiceClient.GetBlobContainerClient("conversation-references");
        _logger = logger;
    }

    public void AddOrUpdate(string userObjectId, ConversationReference reference)
    {
        _cache.AddOrUpdate(userObjectId, reference, (_, _) => reference);

        // Fire-and-forget persist to blob
        _ = PersistAsync(userObjectId, reference);
    }

    public ConversationReference? Get(string userObjectId)
    {
        _cache.TryGetValue(userObjectId, out var reference);
        return reference;
    }

    /// <summary>
    /// Loads all conversation references from blob storage into the in-memory cache.
    /// Called once at startup.
    /// </summary>
    public async Task LoadAsync()
    {
        if (_cacheLoaded) return;

        try
        {
            await foreach (var blob in _container.GetBlobsAsync())
            {
                var client = _container.GetBlobClient(blob.Name);
                var response = await client.DownloadContentAsync();
                var reference = JsonSerializer.Deserialize<ConversationReference>(
                    response.Value.Content.ToString(), JsonOptions);

                if (reference is not null)
                {
                    var userId = Path.GetFileNameWithoutExtension(blob.Name);
                    _cache.TryAdd(userId, reference);
                }
            }

            _cacheLoaded = true;
            _logger.LogInformation("Loaded {Count} conversation references from blob storage", _cache.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to load conversation references from blob storage");
        }
    }

    private async Task PersistAsync(string userObjectId, ConversationReference reference)
    {
        try
        {
            var client = _container.GetBlobClient($"{userObjectId}.json");
            var json = JsonSerializer.Serialize(reference, JsonOptions);
            await client.UploadAsync(BinaryData.FromString(json), overwrite: true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to persist conversation reference for {UserId}", userObjectId);
        }
    }
}
