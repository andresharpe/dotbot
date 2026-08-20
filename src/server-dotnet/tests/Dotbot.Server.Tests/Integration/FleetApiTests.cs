using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Dotbot.Server.Tests.Integration.TestDoubles;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using System.Net;
using System.Text.Json;

namespace Dotbot.Server.Tests.Integration;

// End-to-end coverage of the Fleet mock endpoints through the running app, which
// also validates that the shipped Mock/*.json fixtures deserialize correctly.
// WebApplicationFactory runs in the Development environment, so DevelopmentAuthMiddleware
// injects an authenticated synthetic user; the AlwaysAdministratorService lets it clear
// DashboardAuthMiddleware's admin gate (the base factory's default denies everyone).
public class FleetApiTests : IClassFixture<DotbotApiFactory>
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);
    private readonly HttpClient _client;

    public FleetApiTests(DotbotApiFactory factory)
    {
        _client = factory
            .WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            {
                services.RemoveAll<IAdministratorService>();
                services.AddSingleton<IAdministratorService, AlwaysAdministratorService>();
            }))
            .CreateClient(new WebApplicationFactoryClientOptions
            {
                AllowAutoRedirect = false,
            });
    }

    [Fact]
    public async Task GetInstances_ReturnsMockFleet()
    {
        var resp = await _client.GetAsync("/api/fleet/instances");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);

        var instances = await Deserialize<List<FleetInstanceDto>>(resp);
        Assert.Equal(6, instances.Count);
        Assert.Contains(instances, i => i.InstanceId == "atlas-prod" && i.Kind == "outpost");
        Assert.Contains(instances, i => i.Kind == "drone" && i.DroneUtilization != null);
        Assert.Contains(instances, i => i.Status == "stale");
        Assert.Contains(instances, i => i.Status == "error");
    }

    [Fact]
    public async Task GetAlerts_Active_ReturnsOnlyActive()
    {
        var resp = await _client.GetAsync("/api/fleet/alerts?status=active");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);

        var alerts = await Deserialize<List<FleetAlertDto>>(resp);
        Assert.NotEmpty(alerts);
        Assert.All(alerts, a => Assert.Equal("active", a.Status));
    }

    [Fact]
    public async Task GetAlerts_Cleared_ReturnsHistoryWithResolvedAt()
    {
        var resp = await _client.GetAsync("/api/fleet/alerts?status=cleared");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);

        var alerts = await Deserialize<List<FleetAlertDto>>(resp);
        Assert.NotEmpty(alerts);
        Assert.All(alerts, a =>
        {
            Assert.Equal("cleared", a.Status);
            Assert.NotNull(a.ResolvedAt);
        });
    }

    [Fact]
    public async Task GetAlerts_NoFilter_ReturnsActiveAndCleared()
    {
        var resp = await _client.GetAsync("/api/fleet/alerts");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);

        var alerts = await Deserialize<List<FleetAlertDto>>(resp);
        Assert.Contains(alerts, a => a.Status == "active");
        Assert.Contains(alerts, a => a.Status == "cleared");
    }

    private static async Task<T> Deserialize<T>(HttpResponseMessage resp)
    {
        var json = await resp.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(json, JsonOpts)!;
    }
}
