using Dotbot.Server.Tests.Integration.TestDoubles;

namespace Dotbot.Server.Tests.Integration;

public abstract class IntegrationTestBase : IClassFixture<DotbotApiFactory>, IAsyncLifetime
{
    protected HttpClient Client { get; }
    protected DotbotApiFactory Factory { get; }

    protected IntegrationTestBase(DotbotApiFactory factory)
    {
        // Disable auto-redirect so middleware tests can assert the 302 + Set-Cookie that
        // /respond returns on JTI consumption, rather than the redirected GET that follows.
        // HttpClient still tracks Set-Cookie headers regardless of this flag.
        Client = factory.CreateClient(new Microsoft.AspNetCore.Mvc.Testing.WebApplicationFactoryClientOptions
        {
            AllowAutoRedirect = false,
        });
        Client.DefaultRequestHeaders.Add("X-Api-Key", DotbotApiFactory.TestApiKey);
        Factory = factory;
    }

    public async Task InitializeAsync()
    {
        await Factory.TemplateStorage.ResetAsync();
        await Factory.InstanceStorage.ResetAsync();
        await Factory.TokenStorage.ResetAsync();
        await Factory.AttachmentStorage.ResetAsync();
    }

    public Task DisposeAsync() => Task.CompletedTask;
}
