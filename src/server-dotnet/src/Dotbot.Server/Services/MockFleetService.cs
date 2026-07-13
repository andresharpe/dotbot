using System.Text.Json;
using Dotbot.Server.Models;

namespace Dotbot.Server.Services;

// Serves Fleet dashboard data (#547) from static JSON fixtures under
// ContentRootPath/Mock, loaded once at construction (fail-fast on a missing or
// malformed fixture). #598 replaces this with a live HTTP-backed IFleetService;
// the DTO contract and endpoint signatures stay fixed across that swap.
public sealed class MockFleetService : IFleetService
{
    private readonly IReadOnlyList<FleetInstanceDto> _instances;
    private readonly IReadOnlyList<FleetAlertDto> _alerts;

    public MockFleetService(IWebHostEnvironment env)
        : this(Path.Combine(env.ContentRootPath, "Mock"))
    {
    }

    // Path-based ctor for unit tests (see InternalsVisibleTo in the csproj).
    internal MockFleetService(string mockDirectory)
    {
        _instances = Load<FleetInstanceDto>(Path.Combine(mockDirectory, "fleet-instances.json"));
        _alerts = Load<FleetAlertDto>(Path.Combine(mockDirectory, "fleet-alerts.json"));
    }

    public Task<IReadOnlyList<FleetInstanceDto>> GetInstancesAsync() =>
        Task.FromResult(_instances);

    public Task<IReadOnlyList<FleetAlertDto>> GetAlertsAsync(string? status = null)
    {
        if (string.IsNullOrWhiteSpace(status))
            return Task.FromResult(_alerts);

        IReadOnlyList<FleetAlertDto> filtered = _alerts
            .Where(a => string.Equals(a.Status, status, StringComparison.OrdinalIgnoreCase))
            .ToList();
        return Task.FromResult(filtered);
    }

    private static IReadOnlyList<T> Load<T>(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Fleet mock fixture not found: {path}", path);

        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<List<T>>(json, JsonSerializerOptions.Web)
            ?? throw new InvalidOperationException($"Fleet mock fixture is empty or invalid: {path}");
    }
}
