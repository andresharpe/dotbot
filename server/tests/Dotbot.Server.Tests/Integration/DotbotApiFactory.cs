using Dotbot.Server.Services;
using Dotbot.Server.Tests.Integration.TestDoubles;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;

namespace Dotbot.Server.Tests.Integration;

public sealed class DotbotApiFactory : WebApplicationFactory<Program>
{
    internal const string TestApiKey = "integration-test-key-abc123";

    // Small non-default caps so cap-enforcement tests also catch options-binding regressions.
    internal const int TestMaxAttachments = 2;
    internal const int TestMaxReferenceLinks = 2;

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
                ["Validation:QuestionTemplate:MaxAttachments"] = TestMaxAttachments.ToString(),
                ["Validation:QuestionTemplate:MaxReferenceLinks"] = TestMaxReferenceLinks.ToString(),
            });
        });

        builder.ConfigureServices(services =>
        {
            // Drop hosted services that aren't exercised by these HTTP tests:
            //  - M365 Agents BackgroundQueue.* (HostedTaskService, HostedActivityService) —
            //    StopAsync recursively acquires a ReaderWriterLockSlim write lock,
            //    throwing LockRecursionException on Linux/macOS during host shutdown.
            //  - Dotbot.Server.Services.ReminderEscalationService — enumerates Azure
            //    blobs on startup, triggering Azure SDK retry storms when storage is
            //    unreachable in CI. Hides nondeterminism from test runs.
            var hostedServicesToRemove = services
                .Where(d => d.ServiceType == typeof(IHostedService))
                .Where(d =>
                {
                    var name = d.ImplementationType?.FullName;
                    return name != null
                        && (name.StartsWith("Microsoft.Agents.Hosting.AspNetCore.BackgroundQueue.", StringComparison.Ordinal)
                            || name == "Dotbot.Server.Services.ReminderEscalationService");
                })
                .ToList();
            foreach (var descriptor in hostedServicesToRemove)
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
