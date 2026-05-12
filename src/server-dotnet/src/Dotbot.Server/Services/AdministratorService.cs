using Azure;
using Azure.Storage.Blobs;
using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace Dotbot.Server.Services;

public class AdministratorService : IAdministratorService
{
    private readonly BlobContainerClient _container;
    private readonly StoragePathResolver _paths;
    private readonly ILogger<AdministratorService> _logger;
    private readonly string[] _seedAdministrators;

    private HashSet<string>? _cachedAdmins;
    private DateTime _cacheExpiry = DateTime.MinValue;
    private readonly SemaphoreSlim _lock = new(1, 1);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public AdministratorService(
        BlobServiceClient blob,
        StoragePathResolver paths,
        IOptions<AuthSettings> authSettings,
        ILogger<AdministratorService> logger)
    {
        _container = blob.GetBlobContainerClient("answers");
        _paths = paths;
        _logger = logger;
        _seedAdministrators = authSettings.Value.SeedAdministrators;
    }

    public async Task<bool> IsAdministratorAsync(string email)
    {
        var admins = await GetAdminsAsync();
        return admins.Contains(email.ToLowerInvariant());
    }

    public async Task SeedIfEmptyAsync()
    {
        var path = _paths.AdministratorsPath();
        var blob = _container.GetBlobClient(path);

        try
        {
            await blob.GetPropertiesAsync();
            _logger.LogInformation("Administrators config already exists at {Path}", path);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            var data = new AdministratorsConfig { Administrators = _seedAdministrators.ToList() };
            var json = JsonSerializer.Serialize(data, JsonOptions);
            await blob.UploadAsync(BinaryData.FromString(json), overwrite: false);
            _logger.LogInformation("Seeded administrators config with {Count} users at {Path}", _seedAdministrators.Length, path);
        }
    }

    private async Task<HashSet<string>> GetAdminsAsync()
    {
        if (_cachedAdmins is not null && DateTime.UtcNow < _cacheExpiry)
            return _cachedAdmins;

        await _lock.WaitAsync();
        try
        {
            if (_cachedAdmins is not null && DateTime.UtcNow < _cacheExpiry)
                return _cachedAdmins;

            var path = _paths.AdministratorsPath();
            var blob = _container.GetBlobClient(path);
            var content = await blob.DownloadContentAsync();
            var config = JsonSerializer.Deserialize<AdministratorsConfig>(content.Value.Content.ToString(), JsonOptions);

            _cachedAdmins = new HashSet<string>(
                config?.Administrators?.Select(e => e.ToLowerInvariant()) ?? [],
                StringComparer.OrdinalIgnoreCase);
            _cacheExpiry = DateTime.UtcNow.AddMinutes(5);

            _logger.LogDebug("Refreshed administrator cache: {Count} entries", _cachedAdmins.Count);
            return _cachedAdmins;
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            _logger.LogWarning("Administrators config not found, returning empty set");
            _cachedAdmins = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            _cacheExpiry = DateTime.UtcNow.AddMinutes(1);
            return _cachedAdmins;
        }
        finally
        {
            _lock.Release();
        }
    }

    private class AdministratorsConfig
    {
        public List<string> Administrators { get; set; } = [];
    }
}
