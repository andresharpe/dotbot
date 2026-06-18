namespace Dotbot.Server.Models;

public class MagicLinkToken
{
    public required string Jti { get; set; }
    public required string Email { get; set; }
    public required Guid QuestionInstanceId { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public required DateTime ExpiresAt { get; set; }
    public bool Used { get; set; }
    public DateTime? UsedAt { get; set; }
    public string? UsedByDeviceTokenId { get; set; }
}
