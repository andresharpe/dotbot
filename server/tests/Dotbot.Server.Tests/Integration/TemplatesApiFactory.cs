using Dotbot.Server.Services;
using Dotbot.Server.Tests.Integration.TestDoubles;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;

namespace Dotbot.Server.Tests.Integration;

public sealed class TemplatesApiFactory : WebApplicationFactory<Program>
{
    internal const string TestApiKey = "integration-test-key-abc123";

    public InMemoryTemplateStorage Storage { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        // ConfigureAppConfiguration is guaranteed to run before the host builds its service
        // container, so these values are visible to Program.cs and all middleware constructors
        // regardless of ASPNETCORE_ENVIRONMENT (appsettings.Development.json is not loaded on CI).
        builder.ConfigureAppConfiguration(config =>
        {
            config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["BlobStorage:ConnectionString"] = "UseDevelopmentStorage=true",
                ["ApiSecurity:ApiKey"] = TestApiKey,
                ["Auth:JwtSigningKey"] = "integration-test-signing-key-32-chars!!",
                ["Auth:JwtIssuer"] = "dotbot-test",
                ["Auth:JwtAudience"] = "dotbot-test",
            });
        });

        builder.ConfigureServices(services =>
        {
            // M365 Agents SDK's BackgroundQueue hosted services (HostedTaskService,
            // HostedActivityService) recursively acquire a ReaderWriterLockSlim write
            // lock during host shutdown, throwing LockRecursionException on Linux/macOS.
            // The agent runtime is not exercised by these HTTP tests, so drop the
            // hosted services before the host runs.
            var backgroundQueueDescriptors = services
                .Where(d => d.ServiceType == typeof(IHostedService)
                    && (d.ImplementationType?.FullName?.StartsWith(
                        "Microsoft.Agents.Hosting.AspNetCore.BackgroundQueue.",
                        StringComparison.Ordinal) ?? false))
                .ToList();
            foreach (var descriptor in backgroundQueueDescriptors)
                services.Remove(descriptor);

            // Replace the three DI-blocking services with in-process test doubles.
            services.RemoveAll<ITemplateStorageService>();
            services.RemoveAll<IAdministratorService>();
            services.RemoveAll<IConversationReferenceStore>();

            services.AddSingleton<ITemplateStorageService>(Storage);
            services.AddSingleton<IAdministratorService>(new NullAdministratorService());
            services.AddSingleton<IConversationReferenceStore>(new NullConversationReferenceStore());
        });
    }
}
