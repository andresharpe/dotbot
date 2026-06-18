using System.Net.Http.Headers;

namespace Dotbot.Server.Services;

/// <summary>
/// Shared service for acquiring Microsoft Graph access tokens via client credentials.
/// Used by UserResolverService and EmailDeliveryProvider.
/// </summary>
public class GraphTokenService
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IConfiguration _config;
    private readonly ILogger<GraphTokenService> _logger;

    private string? _cachedToken;
    private DateTime _tokenExpiry = DateTime.MinValue;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public GraphTokenService(
        IHttpClientFactory httpClientFactory,
        IConfiguration config,
        ILogger<GraphTokenService> logger)
    {
        _httpClientFactory = httpClientFactory;
        _config = config;
        _logger = logger;
    }

    /// <summary>
    /// Returns a cached Graph access token, refreshing if needed.
    /// </summary>
    public async Task<string> GetTokenAsync()
    {
        if (_cachedToken is not null && DateTime.UtcNow < _tokenExpiry)
            return _cachedToken;

        await _lock.WaitAsync();
        try
        {
            if (_cachedToken is not null && DateTime.UtcNow < _tokenExpiry)
                return _cachedToken;

            var tenantId = _config["Connections:BotServiceConnection:Settings:TenantId"]
                ?? _config["TokenValidation:TenantId"]
                ?? throw new InvalidOperationException("TenantId not configured");
            var clientId = _config["Connections:BotServiceConnection:Settings:ClientId"]
                ?? _config["Connections:ServiceConnection:Settings:ClientId"]
                ?? throw new InvalidOperationException("ClientId not configured");
            var clientSecret = _config["Connections:BotServiceConnection:Settings:ClientSecret"]
                ?? _config["Connections:ServiceConnection:Settings:ClientSecret"]
                ?? throw new InvalidOperationException("ClientSecret not configured");

            var client = _httpClientFactory.CreateClient();
            var tokenResponse = await client.PostAsync(
                $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token",
                new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"] = "client_credentials",
                    ["client_id"] = clientId,
                    ["client_secret"] = clientSecret,
                    ["scope"] = "https://graph.microsoft.com/.default"
                }));

            if (!tokenResponse.IsSuccessStatusCode)
            {
                var body = await tokenResponse.Content.ReadAsStringAsync();
                throw new InvalidOperationException($"Failed to get Graph token: {body}");
            }

            var tokenJson = await tokenResponse.Content.ReadFromJsonAsync<System.Text.Json.JsonElement>();
            _cachedToken = tokenJson.GetProperty("access_token").GetString()!;
            var expiresIn = tokenJson.GetProperty("expires_in").GetInt32();
            _tokenExpiry = DateTime.UtcNow.AddSeconds(expiresIn - 60);

            return _cachedToken;
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>
    /// Creates an HttpClient with the Graph Bearer token already set.
    /// </summary>
    public async Task<HttpClient> CreateAuthenticatedClientAsync()
    {
        var token = await GetTokenAsync();
        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }
}
