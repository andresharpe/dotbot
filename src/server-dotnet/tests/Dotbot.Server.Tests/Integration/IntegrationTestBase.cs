using Dotbot.Server.Tests.Integration.TestDoubles;

namespace Dotbot.Server.Tests.Integration;

public abstract class IntegrationTestBase : IClassFixture<DotbotApiFactory>, IAsyncLifetime
{
    protected HttpClient Client { get; }
    protected InMemoryTemplateStorage Storage { get; }

    protected IntegrationTestBase(DotbotApiFactory factory)
    {
        Client = factory.CreateClient();
        Client.DefaultRequestHeaders.Add("X-Api-Key", DotbotApiFactory.TestApiKey);
        Storage = factory.Storage;
    }

    public async Task InitializeAsync()
    {
        await Storage.ResetAsync();
    }

    public Task DisposeAsync() => Task.CompletedTask;
}
