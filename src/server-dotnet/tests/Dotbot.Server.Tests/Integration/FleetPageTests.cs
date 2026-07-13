using Dotbot.Server.Services;
using Dotbot.Server.Tests.Integration.TestDoubles;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using System.Net;

namespace Dotbot.Server.Tests.Integration;

// Drives the Razor rendering for the re-homed surfaces: Fleet is the landing (/),
// the Q&A dashboard moved to /decisions, and the shell rail marks the active item
// from ViewData["ActiveRail"]. Browser-only behaviour (fleet.js/CSS) is out of scope.
public class FleetPageTests : IClassFixture<DotbotApiFactory>
{
    private readonly HttpClient _client;

    public FleetPageTests(DotbotApiFactory factory)
    {
        _client = factory
            .WithWebHostBuilder(builder => builder.ConfigureServices(services =>
            {
                services.RemoveAll<IAdministratorService>();
                services.AddSingleton<IAdministratorService, AlwaysAdministratorService>();
            }))
            .CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
    }

    [Fact]
    public async Task Root_RendersFleetLanding_WithFleetRailActive()
    {
        var resp = await _client.GetAsync("/");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var html = await resp.Content.ReadAsStringAsync();

        Assert.Contains("<title>Fleet - Dotbot</title>", html);
        Assert.Contains("id=\"fleet-instances-list\"", html);
        Assert.Contains("/js/fleet.js", html);
        // Fleet rail item is the active destination.
        Assert.Contains("href=\"/\" aria-current=\"page\"", html);
        // Decisions rail item is present but not active.
        Assert.Contains("href=\"/decisions\"", html);
        Assert.DoesNotContain("href=\"/decisions\" aria-current=\"page\"", html);
    }

    [Fact]
    public async Task Decisions_RendersQaDashboard_WithDecisionsRailActive()
    {
        var resp = await _client.GetAsync("/decisions");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var html = await resp.Content.ReadAsStringAsync();

        Assert.Contains("id=\"instances-list\"", html);
        Assert.Contains("/js/dashboard.js", html);
        Assert.Contains("href=\"/decisions\" aria-current=\"page\"", html);
        // Fleet rail item present but not active on this page.
        Assert.DoesNotContain("href=\"/\" aria-current=\"page\"", html);
    }
}
