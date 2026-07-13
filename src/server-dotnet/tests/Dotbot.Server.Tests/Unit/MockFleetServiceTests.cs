using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Unit;

// Exercises MockFleetService against controlled fixtures written to a temp dir
// (constructed via the internal path-based ctor). The real shipped fixtures are
// validated end-to-end by FleetApiTests through the running app.
public class MockFleetServiceTests : IDisposable
{
    private readonly string _dir;

    public MockFleetServiceTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "fleet-mock-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "fleet-instances.json"), InstancesJson);
        File.WriteAllText(Path.Combine(_dir, "fleet-alerts.json"), AlertsJson);
    }

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private MockFleetService Service() => new(_dir);

    [Fact]
    public async Task GetInstances_ReturnsAll_WithDroneUtilizationOnlyForDrones()
    {
        var instances = await Service().GetInstancesAsync();
        Assert.Equal(3, instances.Count);

        var outpost = instances.Single(i => i.InstanceId == "op-online");
        Assert.Equal("outpost", outpost.Kind);
        Assert.Equal("online", outpost.Status);
        Assert.Null(outpost.DroneUtilization);

        Assert.Equal("stale", instances.Single(i => i.InstanceId == "op-stale").Status);

        var drone = instances.Single(i => i.InstanceId == "dr-online");
        Assert.Equal("drone", drone.Kind);
        Assert.Equal(3, drone.TaskCount);
        Assert.NotNull(drone.DroneUtilization);
        Assert.Equal(2, drone.DroneUtilization!.Load);
        Assert.Equal(4, drone.DroneUtilization.MaxConcurrent);
        Assert.Equal(0.96, drone.DroneUtilization.SuccessRate, 3);
        Assert.Equal(312, drone.DroneUtilization.AvgDurationSeconds);
    }

    [Fact]
    public async Task GetAlerts_NoFilter_ReturnsActiveAndCleared()
    {
        var all = await Service().GetAlertsAsync();
        Assert.Equal(3, all.Count);
    }

    [Fact]
    public async Task GetAlerts_Active_ReturnsOnlyActive()
    {
        var active = await Service().GetAlertsAsync("active");
        Assert.Equal(2, active.Count);
        Assert.All(active, a => Assert.Equal("active", a.Status));
        Assert.All(active, a => Assert.Null(a.ResolvedAt));
    }

    [Fact]
    public async Task GetAlerts_Cleared_ReturnsOnlyClearedWithResolvedAt()
    {
        var cleared = await Service().GetAlertsAsync("cleared");
        var alert = Assert.Single(cleared);
        Assert.Equal("cleared", alert.Status);
        Assert.NotNull(alert.ResolvedAt);
    }

    [Fact]
    public async Task GetAlerts_IsCaseInsensitive()
    {
        var active = await Service().GetAlertsAsync("ACTIVE");
        Assert.Equal(2, active.Count);
    }

    [Fact]
    public async Task GetAlerts_UnknownStatus_ReturnsEmpty()
    {
        Assert.Empty(await Service().GetAlertsAsync("bogus"));
    }

    [Fact]
    public void Constructor_MissingFixture_ThrowsFileNotFound()
    {
        var emptyDir = Path.Combine(_dir, "empty");
        Directory.CreateDirectory(emptyDir);
        Assert.Throws<FileNotFoundException>(() => new MockFleetService(emptyDir));
    }

    private const string InstancesJson = """
    [
      { "instanceId": "op-online", "name": "op-online", "kind": "outpost", "status": "online", "orgId": "default", "uptimeSeconds": 1000, "lastHeartbeatAt": "2026-07-13T18:00:00Z", "activeWorkflow": "wf", "taskCount": 1, "version": "4.1.0", "droneUtilization": null },
      { "instanceId": "op-stale", "name": "op-stale", "kind": "outpost", "status": "stale", "orgId": "default", "uptimeSeconds": 500, "lastHeartbeatAt": "2026-07-13T17:00:00Z", "activeWorkflow": null, "taskCount": 0, "version": "4.1.0", "droneUtilization": null },
      { "instanceId": "dr-online", "name": "dr-online", "kind": "drone", "status": "online", "orgId": "default", "uptimeSeconds": 2000, "lastHeartbeatAt": "2026-07-13T18:00:00Z", "activeWorkflow": "wf", "taskCount": 3, "version": "4.1.0", "droneUtilization": { "load": 2, "maxConcurrent": 4, "successRate": 0.96, "avgDurationSeconds": 312 } }
    ]
    """;

    private const string AlertsJson = """
    [
      { "id": "a1", "severity": "critical", "instanceId": "op-stale", "message": "m", "createdAt": "2026-07-13T18:00:00Z", "status": "active", "resolvedAt": null },
      { "id": "a2", "severity": "warning", "instanceId": "dr-online", "message": "m", "createdAt": "2026-07-13T18:01:00Z", "status": "active", "resolvedAt": null },
      { "id": "a3", "severity": "info", "instanceId": "op-online", "message": "m", "createdAt": "2026-07-13T10:00:00Z", "status": "cleared", "resolvedAt": "2026-07-13T10:05:00Z" }
    ]
    """;
}
