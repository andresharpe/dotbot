using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Dotbot.Server.Models;
using System.Text.Json;

namespace Dotbot.Server.Services;

public class TokenStorageService
{
    private readonly BlobContainerClient _container;
    private readonly StoragePathResolver _paths;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public TokenStorageService(BlobServiceClient blob, StoragePathResolver paths)
    {
        _container = blob.GetBlobContainerClient("answers");
        _paths = paths;
    }

    public async Task SaveMagicLinkTokenAsync(MagicLinkToken token)
    {
        var path = _paths.MagicLinkTokenPath(token.Jti);
        var blob = _container.GetBlobClient(path);
        var json = JsonSerializer.Serialize(token, JsonOptions);
        await blob.UploadAsync(BinaryData.FromString(json), overwrite: true);
    }

    public async Task<MagicLinkToken?> GetMagicLinkTokenAsync(string jti)
    {
        try
        {
            var path = _paths.MagicLinkTokenPath(jti);
            var blob = _container.GetBlobClient(path);
            var content = await blob.DownloadContentAsync();
            return JsonSerializer.Deserialize<MagicLinkToken>(content.Value.Content.ToString(), JsonOptions);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    /// <summary>
    /// Atomically marks a magic link token as used via ETag-based optimistic concurrency.
    /// Returns true if successfully marked, false if already used or not found.
    /// </summary>
    public async Task<bool> TryMarkMagicLinkUsedAsync(string jti, string deviceTokenId)
    {
        try
        {
            var path = _paths.MagicLinkTokenPath(jti);
            var blob = _container.GetBlobClient(path);
            var download = await blob.DownloadContentAsync();
            var token = JsonSerializer.Deserialize<MagicLinkToken>(download.Value.Content.ToString(), JsonOptions);
            if (token is null || token.Used)
                return false;

            token.Used = true;
            token.UsedAt = DateTime.UtcNow;
            token.UsedByDeviceTokenId = deviceTokenId;

            var json = JsonSerializer.Serialize(token, JsonOptions);
            var conditions = new BlobRequestConditions { IfMatch = download.Value.Details.ETag };
            await blob.UploadAsync(BinaryData.FromString(json), new BlobUploadOptions { Conditions = conditions });
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status == 404 || ex.Status == 412)
        {
            return false;
        }
    }

    public async Task SaveDeviceTokenAsync(DeviceToken token)
    {
        var path = _paths.DeviceTokenPath(token.DeviceTokenId);
        var blob = _container.GetBlobClient(path);
        var json = JsonSerializer.Serialize(token, JsonOptions);
        await blob.UploadAsync(BinaryData.FromString(json), overwrite: true);
    }

    public async Task<DeviceToken?> GetDeviceTokenAsync(string deviceTokenId)
    {
        try
        {
            var path = _paths.DeviceTokenPath(deviceTokenId);
            var blob = _container.GetBlobClient(path);
            var content = await blob.DownloadContentAsync();
            return JsonSerializer.Deserialize<DeviceToken>(content.Value.Content.ToString(), JsonOptions);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public async Task<bool> RevokeDeviceTokenAsync(string deviceTokenId)
    {
        var token = await GetDeviceTokenAsync(deviceTokenId);
        if (token is null || token.Revoked)
            return false;

        token.Revoked = true;
        token.RevokedAt = DateTime.UtcNow;
        await SaveDeviceTokenAsync(token);
        return true;
    }
}
