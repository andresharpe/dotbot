namespace Dotbot.Server.Services;

public interface IAdministratorService
{
    Task SeedIfEmptyAsync();
    Task<bool> IsAdministratorAsync(string email);
}
