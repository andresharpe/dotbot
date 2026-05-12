using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;

namespace Dotbot.Server.Services;

public class MagicLinkService
{
    private readonly JwtSigningKeyProvider _keyProvider;
    private readonly TokenStorageService _tokenStorage;
    private readonly AuthSettings _settings;
    private readonly ILogger<MagicLinkService> _logger;

    public MagicLinkService(
        JwtSigningKeyProvider keyProvider,
        TokenStorageService tokenStorage,
        IOptions<AuthSettings> settings,
        ILogger<MagicLinkService> logger)
    {
        _keyProvider = keyProvider;
        _tokenStorage = tokenStorage;
        _settings = settings.Value;
        _logger = logger;
    }

    /// <summary>
    /// Generates a magic link URL containing a signed JWT.
    /// The JWT contains the recipient email, instance ID, project ID, and a unique JTI for single-use enforcement.
    /// </summary>
    public async Task<string> GenerateMagicLinkAsync(string email, Guid instanceId, string projectId, string baseUrl)
    {
        var jti = Guid.NewGuid().ToString();
        var now = DateTime.UtcNow;
        var expires = now.AddMinutes(_settings.MagicLinkExpiryMinutes);

        var credentials = await _keyProvider.GetSigningCredentialsAsync();
        var tokenDescriptor = new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity(new[]
            {
                new Claim(JwtRegisteredClaimNames.Email, email),
                new Claim("questionInstanceId", instanceId.ToString()),
                new Claim("projectId", projectId),
                new Claim(JwtRegisteredClaimNames.Jti, jti)
            }),
            Expires = expires,
            IssuedAt = now,
            Issuer = _settings.JwtIssuer,
            Audience = _settings.JwtAudience,
            SigningCredentials = credentials
        };

        var handler = new JwtSecurityTokenHandler();
        var jwt = handler.CreateEncodedJwt(tokenDescriptor);

        // Persist JTI blob for single-use enforcement
        var magicToken = new MagicLinkToken
        {
            Jti = jti,
            Email = email,
            QuestionInstanceId = instanceId,
            ExpiresAt = expires
        };
        await _tokenStorage.SaveMagicLinkTokenAsync(magicToken);

        var url = $"{baseUrl.TrimEnd('/')}/respond?token={Uri.EscapeDataString(jwt)}";
        _logger.LogInformation("Generated magic link for {Email}, instance {InstanceId}", email, instanceId);
        return url;
    }
}
