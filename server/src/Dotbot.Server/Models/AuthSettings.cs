namespace Dotbot.Server.Models;

public class AuthSettings
{
    public string? KeyVaultUri { get; set; }
    public string KeyName { get; set; } = "dotbot-jwt-signing";
    public string? JwtSigningKey { get; set; }
    public string JwtIssuer { get; set; } = "dotbot";
    public string JwtAudience { get; set; } = "dotbot-respond";
    public int MagicLinkExpiryMinutes { get; set; } = 43200;
    public int DeviceTokenExpiryDays { get; set; } = 90;
    public string CookieName { get; set; } = "dotbot_device";
    public string[] SeedAdministrators { get; set; } = [];
}
