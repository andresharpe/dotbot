using Dotbot.Server.Tests.Integration.TestDoubles;

namespace Dotbot.Server.Tests.Integration;

public abstract class IntegrationTestBase : IClassFixture<TemplatesApiFactory>, IAsyncLifetime
{
    protected HttpClient Client { get; }
    protected InMemoryTemplateStorage Storage { get; }

    protected IntegrationTestBase(TemplatesApiFactory factory)
    {
        Client = factory.CreateClient();
        Client.DefaultRequestHeaders.Add("X-Api-Key", TemplatesApiFactory.TestApiKey);
        Storage = factory.Storage;
    }

    public async Task InitializeAsync()
    {
        await Storage.ResetAsync();
    }

    public async Task DisposeAsync()
    {
        await Task.CompletedTask;
    }
}
