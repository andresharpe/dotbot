using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Microsoft.Extensions.Options;
using System.IdentityModel.Tokens.Jwt;
using Microsoft.IdentityModel.Tokens;

namespace Dotbot.Server;

/// <summary>
/// Intercepts requests that depend on magic-link or device-cookie authentication.
///
/// Covers:
///   • /respond*                  — web response form (GET + POST)
///   • GET /api/attachments/*     — template-attachment downloads rendered by the
///                                  document-review form. Authorized by the same
///                                  magic-link JWT as /respond; the middleware
///                                  additionally verifies that the JWT's
///                                  questionInstanceId owns the requested storageRef.
///
/// Flow:
///   1. Check ?token= query param → validate JWT, check JTI blob exists and is unused.
///      - GET /respond and GET /api/attachments/*: authenticate without consuming.
///      - POST /respond: validate; Respond page handler decides when to consume.
///   2. Else check dotbot_device cookie (Respond only) → load device blob, validate.
///   3. If neither → 401.
///
/// Expired JWTs (signature valid, exp in the past) return 410 Gone — abandoned
/// partial-batch links should not look like an auth failure.
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
        ITokenStorageService tokenStorage,
        IInstanceStorageService instances,
        ITemplateStorageService templates,
        IOptions<AuthSettings> authSettings,
        ILogger<MagicLinkAuthMiddleware> logger)
    {
        var path = context.Request.Path.Value ?? "";
        var method = context.Request.Method;

        var isRespond = path.StartsWith("/respond", StringComparison.OrdinalIgnoreCase);
        var isAttachmentGet = HttpMethods.IsGet(method)
            && path.StartsWith("/api/attachments", StringComparison.OrdinalIgnoreCase);

        if (!isRespond && !isAttachmentGet)
        {
            await _next(context);
            return;
        }

        // Teams (and other clients) send HEAD requests to preview URLs.
        // These must not consume the single-use magic link token.
        if (isRespond && HttpMethods.IsHead(method))
        {
            context.Response.StatusCode = 200;
            return;
        }

        var settings = authSettings.Value;

        // 1. Check for magic link token in query string
        if (context.Request.Query.TryGetValue("token", out var tokenValue) && !string.IsNullOrEmpty(tokenValue))
        {
            JwtSecurityToken jwtToken;
            try
            {
                var validationParams = await keyProvider.GetValidationParametersAsync();
                var handler = new JwtSecurityTokenHandler();
                handler.ValidateToken(tokenValue!, validationParams, out var validatedToken);
                jwtToken = (JwtSecurityToken)validatedToken;
            }
            catch (SecurityTokenExpiredException ex)
            {
                logger.LogWarning(ex, "Magic link token expired (exp claim in the past)");
                context.Response.StatusCode = StatusCodes.Status410Gone;
                await context.Response.WriteAsync("This link has expired.");
                return;
            }
            catch (Exception ex) when (
                ex is SecurityTokenException ||      // signature, audience, issuer, malformed JWT structure
                ex is ArgumentException)             // token string can't be parsed as JWT at all
            {
                logger.LogWarning(ex, "Invalid magic link token");
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await context.Response.WriteAsync("Invalid or expired token.");
                return;
            }

            var jti = jwtToken.Id;
            var email = jwtToken.Claims.FirstOrDefault(c => c.Type == JwtRegisteredClaimNames.Email)?.Value
                ?? jwtToken.Claims.FirstOrDefault(c => c.Type == "email")?.Value;
            var instanceIdClaim = jwtToken.Claims.FirstOrDefault(c => c.Type == "questionInstanceId")?.Value;
            var projectIdClaim = jwtToken.Claims.FirstOrDefault(c => c.Type == "projectId")?.Value;

            if (string.IsNullOrEmpty(jti) || string.IsNullOrEmpty(email)
                || string.IsNullOrEmpty(instanceIdClaim) || string.IsNullOrEmpty(projectIdClaim))
            {
                logger.LogWarning("Magic link token missing required claims");
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await context.Response.WriteAsync("Invalid token: missing required claims.");
                return;
            }

            // Verify the magic link blob is present and not expired/consumed
            var existingToken = await tokenStorage.GetMagicLinkTokenAsync(jti);
            if (existingToken is null)
            {
                logger.LogWarning("Magic link token {Jti} not found", jti);
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await context.Response.WriteAsync("This link is not recognised.");
                return;
            }
            if (existingToken.ExpiresAt <= DateTime.UtcNow)
            {
                logger.LogWarning("Magic link token {Jti} expired at {ExpiresAt}", jti, existingToken.ExpiresAt);
                context.Response.StatusCode = StatusCodes.Status410Gone;
                await context.Response.WriteAsync("This link has expired.");
                return;
            }
            if (existingToken.Used)
            {
                logger.LogWarning("Magic link token {Jti} already used", jti);
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await context.Response.WriteAsync("This link has already been used.");
                return;
            }

            // Attachment downloads must come from the instance that owns the link
            if (isAttachmentGet)
            {
                var storageRef = ExtractStorageRef(path);
                if (string.IsNullOrEmpty(storageRef))
                {
                    await _next(context);
                    return;
                }

                if (!Guid.TryParse(instanceIdClaim, out var instanceGuid))
                {
                    logger.LogWarning("Magic link token has non-GUID questionInstanceId claim");
                    context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                    await context.Response.WriteAsync("Invalid token: questionInstanceId is malformed.");
                    return;
                }

                if (!await StorageRefBelongsToInstanceAsync(storageRef, projectIdClaim!, instanceGuid, instances, templates))
                {
                    logger.LogWarning(
                        "Attachment {StorageRef} not owned by instance {InstanceId} from token",
                        storageRef, instanceGuid);
                    context.Response.StatusCode = StatusCodes.Status403Forbidden;
                    await context.Response.WriteAsync("This link does not grant access to that attachment.");
                    return;
                }
            }

            // Store JTI so /respond's page handler can consume after the full batch is complete
            context.Items["MagicLinkJti"] = jti;
            context.Items["AuthenticatedEmail"] = email;
            logger.LogInformation("Magic link validated (not consumed) for {Email}, method {Method}, path {Path}",
                email, method, path);

            await _next(context);
            return;
        }

        // 2. Check for device cookie (only valid on /respond — attachment downloads always need the JWT)
        if (isRespond
            && context.Request.Cookies.TryGetValue(settings.CookieName, out var cookieValue)
            && !string.IsNullOrEmpty(cookieValue))
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
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsync("Authentication required. Please use a valid magic link.");
    }

    /// <summary>
    /// Extracts the storage reference from a path like <c>/api/attachments/{**storageRef}</c>.
    /// Returns null if the prefix is missing.
    /// </summary>
    private static string? ExtractStorageRef(string path)
    {
        const string prefix = "/api/attachments/";
        if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return null;
        var tail = path[prefix.Length..];
        return string.IsNullOrWhiteSpace(tail) ? null : tail;
    }

    /// <summary>
    /// Verifies that the requested storageRef is referenced by the template owned by the
    /// JWT's instance. Requires an exact <see cref="QuestionAttachment.BlobPath"/> match —
    /// matching by the AttachmentId prefix alone would grant access to any object stored
    /// under <c>{attachmentId}/*</c>, which on the local-file backend would include the
    /// <c>.meta</c> companion next to the blob (and may include unrelated objects under
    /// future storage layouts). Validator already enforces non-empty <c>BlobPath</c> on
    /// blob-backed template attachments, so this loses no legitimate access.
    /// </summary>
    private static async Task<bool> StorageRefBelongsToInstanceAsync(
        string storageRef,
        string projectId,
        Guid instanceId,
        IInstanceStorageService instances,
        ITemplateStorageService templates)
    {
        var instance = await instances.GetInstanceAsync(projectId, instanceId);
        if (instance is null)
            return false;

        var template = await templates.GetTemplateAsync(projectId, instance.QuestionId, instance.QuestionVersion);
        if (template?.Attachments is null)
            return false;

        foreach (var att in template.Attachments)
        {
            if (att is null) continue;
            if (!string.IsNullOrEmpty(att.BlobPath)
                && string.Equals(att.BlobPath, storageRef, StringComparison.Ordinal))
                return true;
        }
        return false;
    }
}
