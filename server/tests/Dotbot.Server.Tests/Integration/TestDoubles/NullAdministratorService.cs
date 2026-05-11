using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

internal sealed class NullAdministratorService : IAdministratorService
{
    public Task SeedIfEmptyAsync() => Task.CompletedTask;
    public Task<bool> IsAdministratorAsync(string email) => Task.FromResult(false);
}
