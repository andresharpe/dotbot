using Dotbot.Server.Models;

namespace Dotbot.Server.Services;

public interface ITokenStorageService
{
    Task SaveMagicLinkTokenAsync(MagicLinkToken token);
    Task<MagicLinkToken?> GetMagicLinkTokenAsync(string jti);

    /// <summary>
    /// Atomically marks a magic link token as used via ETag-based optimistic concurrency.
    /// Returns true if successfully marked, false if already used or not found.
    /// </summary>
    Task<bool> TryMarkMagicLinkUsedAsync(string jti, string deviceTokenId);

    Task SaveDeviceTokenAsync(DeviceToken token);
    Task<DeviceToken?> GetDeviceTokenAsync(string deviceTokenId);
    Task<bool> RevokeDeviceTokenAsync(string deviceTokenId);
}
