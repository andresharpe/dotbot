using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

// Grants admin to every caller. Used by dashboard-route tests: WebApplicationFactory
// runs in the Development environment, so DevelopmentAuthMiddleware injects an
// authenticated synthetic user; this lets that user clear DashboardAuthMiddleware's
// admin gate (the default NullAdministratorService denies everyone).
internal sealed class AlwaysAdministratorService : IAdministratorService
{
    public Task SeedIfEmptyAsync() => Task.CompletedTask;
    public Task<bool> IsAdministratorAsync(string email) => Task.FromResult(true);
}
