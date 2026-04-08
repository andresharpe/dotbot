using System.Security.Cryptography;
using System.Text;

namespace Dotbot.Server;

/// <summary>
/// Validates the X-Api-Key header on protected endpoints (/api/notify, /api/answers).
/// Skips /api/messages (Bot Framework handles its own auth) and /api/health.
/// </summary>
public class ApiKeyMiddleware
{
    private const string ApiKeyHeader = "X-Api-Key";
    private static readonly string[] ProtectedPrefixes = ["/api/notify", "/api/answers", "/api/instances", "/api/templates", "/api/attachments", "/tokens/revoke"];

    private readonly RequestDelegate _next;
    private readonly byte[] _expectedKeyBytes;

    public ApiKeyMiddleware(RequestDelegate next, IConfiguration config)
    {
        _next = next;

        var key = config["ApiSecurity:ApiKey"]
            ?? throw new InvalidOperationException(
                "ApiSecurity:ApiKey is not configured. Set the ApiSecurity__ApiKey app setting.");

        _expectedKeyBytes = Encoding.UTF8.GetBytes(key);
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var path = context.Request.Path.Value ?? "";

        if (IsProtected(path))
        {
            if (!context.Request.Headers.TryGetValue(ApiKeyHeader, out var providedKey)
                || !IsKeyValid(providedKey!))
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                context.Response.ContentType = "application/json";
                await context.Response.WriteAsync("""{"error":"Missing or invalid API key"}""");
                return;
            }
        }

        await _next(context);
    }

    private static bool IsProtected(string path)
        => ProtectedPrefixes.Any(p => path.StartsWith(p, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Constant-time comparison to prevent timing attacks.
    /// </summary>
    private bool IsKeyValid(string providedKey)
    {
        var providedBytes = Encoding.UTF8.GetBytes(providedKey);
        if (providedBytes.Length != _expectedKeyBytes.Length)
            return false;
        return CryptographicOperations.FixedTimeEquals(providedBytes, _expectedKeyBytes);
    }
}
