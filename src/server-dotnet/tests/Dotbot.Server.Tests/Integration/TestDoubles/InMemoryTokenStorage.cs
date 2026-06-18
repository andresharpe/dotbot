using Dotbot.Server.Models;
using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

/// <summary>
/// In-memory <see cref="ITokenStorageService"/> for integration tests. Holds magic-link
/// JTI blobs and device-token blobs keyed by their respective ids; supports the
/// atomic mark-used path the middleware relies on.
/// </summary>
public sealed class InMemoryTokenStorage : ITokenStorageService
{
    private readonly Dictionary<string, MagicLinkToken> _jtis = new();
    private readonly Dictionary<string, DeviceToken> _devices = new();
    private readonly object _gate = new();

    public IReadOnlyDictionary<string, MagicLinkToken> Jtis => _jtis;
    public IReadOnlyDictionary<string, DeviceToken> Devices => _devices;

    public Task ResetAsync()
    {
        lock (_gate) { _jtis.Clear(); _devices.Clear(); }
        return Task.CompletedTask;
    }

    public Task SaveMagicLinkTokenAsync(MagicLinkToken token)
    {
        lock (_gate) { _jtis[token.Jti] = token; }
        return Task.CompletedTask;
    }

    public Task<MagicLinkToken?> GetMagicLinkTokenAsync(string jti)
    {
        lock (_gate) { return Task.FromResult(_jtis.TryGetValue(jti, out var v) ? v : null); }
    }

    public Task<bool> TryMarkMagicLinkUsedAsync(string jti, string deviceTokenId)
    {
        lock (_gate)
        {
            if (!_jtis.TryGetValue(jti, out var token) || token.Used)
                return Task.FromResult(false);
            token.Used = true;
            token.UsedAt = DateTime.UtcNow;
            token.UsedByDeviceTokenId = deviceTokenId;
            return Task.FromResult(true);
        }
    }

    public Task SaveDeviceTokenAsync(DeviceToken token)
    {
        lock (_gate) { _devices[token.DeviceTokenId] = token; }
        return Task.CompletedTask;
    }

    public Task<DeviceToken?> GetDeviceTokenAsync(string deviceTokenId)
    {
        lock (_gate) { return Task.FromResult(_devices.TryGetValue(deviceTokenId, out var v) ? v : null); }
    }

    public Task<bool> RevokeDeviceTokenAsync(string deviceTokenId)
    {
        lock (_gate)
        {
            if (!_devices.TryGetValue(deviceTokenId, out var d) || d.Revoked)
                return Task.FromResult(false);
            d.Revoked = true;
            d.RevokedAt = DateTime.UtcNow;
            return Task.FromResult(true);
        }
    }
}
