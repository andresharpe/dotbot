using System.Text.Json;

namespace Dotbot.Server.Services;

/// <summary>
/// Resolves user identifiers (email or object ID) to AAD object IDs
/// using Microsoft Graph with client credentials via shared GraphTokenService.
/// </summary>
public class UserResolverService
{
    private readonly GraphTokenService _graphTokenService;
    private readonly ILogger<UserResolverService> _logger;

    public UserResolverService(
        GraphTokenService graphTokenService,
        ILogger<UserResolverService> logger)
    {
        _graphTokenService = graphTokenService;
        _logger = logger;
    }

    /// <summary>
    /// Returns true if the identifier looks like an email address.
    /// </summary>
    public static bool IsEmail(string identifier) => identifier.Contains('@');

    /// <summary>
    /// Resolves an email or object ID to an AAD object ID.
    /// If the input is already a GUID, returns it as-is.
    /// </summary>
    public async Task<string> ResolveUserIdAsync(string identifier)
    {
        if (!IsEmail(identifier))
            return identifier;

        var client = await _graphTokenService.CreateAuthenticatedClientAsync();

        var response = await client.GetAsync(
            $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(identifier)}?$select=id");

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            _logger.LogError("Graph API error resolving {Email}: {Status} {Body}",
                identifier, response.StatusCode, body);
            throw new InvalidOperationException(
                $"Could not resolve user '{identifier}'. Ensure the email exists in the tenant.");
        }

        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        var objectId = json.GetProperty("id").GetString()
            ?? throw new InvalidOperationException($"Graph returned no id for '{identifier}'");

        _logger.LogInformation("Resolved {Email} to {ObjectId}", identifier, objectId);
        return objectId;
    }

    /// <summary>
    /// Resolves an email address, returning both the email and the AAD object ID.
    /// </summary>
    public async Task<(string Email, string AadObjectId)> ResolveUserWithEmailAsync(string email)
    {
        var objectId = await ResolveUserIdAsync(email);
        return (email, objectId);
    }

    /// <summary>
    /// Resolves an AAD object ID to an email address via Microsoft Graph.
    /// Returns mail (falling back to userPrincipalName), or null on failure — non-critical.
    /// </summary>
    public async Task<string?> ResolveEmailAsync(string objectId)
    {
        try
        {
            var client = await _graphTokenService.CreateAuthenticatedClientAsync();
            var response = await client.GetAsync(
                $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(objectId)}?$select=mail,userPrincipalName");

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Could not resolve email for {ObjectId}: {Status}",
                    objectId, response.StatusCode);
                return null;
            }

            var json = await response.Content.ReadFromJsonAsync<JsonElement>();
            return json.TryGetProperty("mail", out var mail) && mail.ValueKind == JsonValueKind.String
                ? mail.GetString()
                : json.TryGetProperty("userPrincipalName", out var upn) && upn.ValueKind == JsonValueKind.String
                    ? upn.GetString()
                    : null;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to resolve email for {ObjectId}", objectId);
            return null;
        }
    }

    /// <summary>
    /// Resolves a user's locale information (timezone and country) from Microsoft Graph.
    /// Returns (TimeZoneInfo, CountryCode?) — falls back gracefully on missing data.
    /// </summary>
    public async Task<(TimeZoneInfo TimeZone, string? CountryCode)> ResolveUserLocaleAsync(
        string userIdOrEmail, TimeZoneInfo fallbackTimeZone)
    {
        try
        {
            var client = await _graphTokenService.CreateAuthenticatedClientAsync();
            var response = await client.GetAsync(
                $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(userIdOrEmail)}?$select=mailboxSettings,usageLocation");

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Could not resolve locale for {User}: {Status}",
                    userIdOrEmail, response.StatusCode);
                return (fallbackTimeZone, null);
            }

            var json = await response.Content.ReadFromJsonAsync<System.Text.Json.JsonElement>();

            // Extract timezone from mailboxSettings.timeZone (Windows timezone ID)
            TimeZoneInfo tz = fallbackTimeZone;
            if (json.TryGetProperty("mailboxSettings", out var mailbox) &&
                mailbox.TryGetProperty("timeZone", out var tzProp) &&
                tzProp.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var tzId = tzProp.GetString();
                if (!string.IsNullOrEmpty(tzId))
                {
                    try
                    {
                        tz = TimeZoneInfo.FindSystemTimeZoneById(tzId);
                    }
                    catch (TimeZoneNotFoundException)
                    {
                        _logger.LogWarning("Unknown timezone '{TimeZoneId}' for {User}, using fallback",
                            tzId, userIdOrEmail);
                    }
                }
            }

            // Extract country from usageLocation (2-letter ISO code)
            string? country = null;
            if (json.TryGetProperty("usageLocation", out var loc) &&
                loc.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                country = loc.GetString();
            }

            return (tz, country);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to resolve locale for {User}", userIdOrEmail);
            return (fallbackTimeZone, null);
        }
    }

    /// <summary>
    /// Resolves an email address to a display name via Microsoft Graph.
    /// Returns null on any failure — display name is non-critical.
    /// </summary>
    public async Task<string?> ResolveDisplayNameAsync(string email)
    {
        try
        {
            var client = await _graphTokenService.CreateAuthenticatedClientAsync();
            var response = await client.GetAsync(
                $"https://graph.microsoft.com/v1.0/users/{Uri.EscapeDataString(email)}?$select=displayName");

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Could not resolve display name for {Email}: {Status}",
                    email, response.StatusCode);
                return null;
            }

            var json = await response.Content.ReadFromJsonAsync<JsonElement>();
            return json.GetProperty("displayName").GetString();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to resolve display name for {Email}", email);
            return null;
        }
    }
}
