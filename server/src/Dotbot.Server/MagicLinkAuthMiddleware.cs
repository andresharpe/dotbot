using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Microsoft.Extensions.Options;
using System.IdentityModel.Tokens.Jwt;
using Microsoft.IdentityModel.Tokens;

namespace Dotbot.Server;

/// <summary>
/// Intercepts requests to /respond* paths and enforces magic-link or device-cookie authentication.
/// Flow:
///   1. Check ?token= query param → validate JWT, check JTI blob exists and is unused
///      - GET: authenticate without consuming (user is viewing the question)
///      - POST: atomically mark used, create device token, set cookie (user is submitting answer)
///   2. Else check dotbot_device cookie → load device blob, validate not expired/revoked
///   3. If neither → 401
/// Sets HttpContext.Items["AuthenticatedEmail"] for downstream use.
/// </summary>
public class MagicLinkAuthMiddleware
{
    private readonly RequestDelegate _next;

    public MagicLinkAuthMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(
        HttpContext context,
        JwtSigningKeyProvider keyProvider,
        TokenStorageService tokenStorage,
        IOptions<AuthSettings> authSettings,
        ILogger<MagicLinkAuthMiddleware> logger)
    {
        var path = context.Request.Path.Value ?? "";
        if (!path.StartsWith("/respond", StringComparison.OrdinalIgnoreCase))
        {
            await _next(context);
            return;
        }

        // Teams (and other clients) send HEAD requests to preview URLs.
        // These must not consume the single-use magic link token.
        if (HttpMethods.IsHead(context.Request.Method))
        {
            context.Response.StatusCode = 200;
            return;
        }

        var settings = authSettings.Value;

        // 1. Check for magic link token in query string
        if (context.Request.Query.TryGetValue("token", out var tokenValue) && !string.IsNullOrEmpty(tokenValue))
        {
            try
            {
                var validationParams = await keyProvider.GetValidationParametersAsync();
                var handler = new JwtSecurityTokenHandler();
                var principal = handler.ValidateToken(tokenValue!, validationParams, out var validatedToken);
                var jwtToken = (JwtSecurityToken)validatedToken;

                var jti = jwtToken.Id;
                var email = jwtToken.Claims.FirstOrDefault(c => c.Type == JwtRegisteredClaimNames.Email)?.Value
                    ?? jwtToken.Claims.FirstOrDefault(c => c.Type == "email")?.Value;

                if (string.IsNullOrEmpty(jti) || string.IsNullOrEmpty(email))
                {
                    logger.LogWarning("Magic link token missing required claims (jti or email)");
                    context.Response.StatusCode = 401;
                    await context.Response.WriteAsync("Invalid token: missing required claims.");
                    return;
                }

                // Verify the magic link hasn't already been used
                var existingToken = await tokenStorage.GetMagicLinkTokenAsync(jti);
                if (existingToken is null || existingToken.Used)
                {
                    logger.LogWarning("Magic link token {Jti} already used or not found", jti);
                    context.Response.StatusCode = 401;
                    await context.Response.WriteAsync("This link has already been used or has expired.");
                    return;
                }

                // Store JTI so the page handler can consume after successful processing
                context.Items["MagicLinkJti"] = jti;
                logger.LogInformation("Magic link validated (not consumed) for {Email}, method {Method}", email, context.Request.Method);

                context.Items["AuthenticatedEmail"] = email;
                await _next(context);
                return;
            }
            catch (SecurityTokenException ex)
            {
                logger.LogWarning(ex, "Invalid magic link token");
                context.Response.StatusCode = 401;
                await context.Response.WriteAsync("Invalid or expired token.");
                return;
            }
        }

        // 2. Check for device cookie
        if (context.Request.Cookies.TryGetValue(settings.CookieName, out var cookieValue) && !string.IsNullOrEmpty(cookieValue))
        {
            var deviceToken = await tokenStorage.GetDeviceTokenAsync(cookieValue);
            if (deviceToken is not null && !deviceToken.Revoked && deviceToken.ExpiresAt > DateTime.UtcNow)
            {
                context.Items["AuthenticatedEmail"] = deviceToken.Email;
                logger.LogDebug("Device cookie authenticated {Email}", deviceToken.Email);
                await _next(context);
                return;
            }

            // Cookie invalid — clear it
            context.Response.Cookies.Delete(settings.CookieName);
        }

        // 3. No valid auth
        context.Response.StatusCode = 401;
        await context.Response.WriteAsync("Authentication required. Please use a valid magic link.");
    }
}
