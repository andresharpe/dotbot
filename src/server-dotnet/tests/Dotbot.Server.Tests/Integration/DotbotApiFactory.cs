using Dotbot.Server.Services;
using Dotbot.Server.Tests.Integration.TestDoubles;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
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

    public InMemoryTemplateStorage TemplateStorage { get; } = new();
    public InMemoryInstanceStorage InstanceStorage { get; } = new();
    public InMemoryTokenStorage TokenStorage { get; } = new();
    public InMemoryAttachmentStorage AttachmentStorage { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        // Provide minimum required configuration so the host boots without Azure resources.
        builder.UseSetting("BlobStorage:ConnectionString", "UseDevelopmentStorage=true");
        builder.UseSetting("ApiSecurity:ApiKey", TestApiKey);
        builder.UseSetting("Validation:QuestionTemplate:MaxAttachments", TestMaxAttachments.ToString());
        builder.UseSetting("Validation:QuestionTemplate:MaxReferenceLinks", TestMaxReferenceLinks.ToString());

        // Stub required Auth config so JwtSigningKeyProvider and MagicLinkService don't fail to resolve.
        builder.UseSetting("Auth:JwtSigningKey", "integration-test-signing-key-32-chars!!");
        builder.UseSetting("Auth:JwtIssuer", "dotbot-test");
        builder.UseSetting("Auth:JwtAudience", "dotbot-test");

        // Enable test-mode endpoints (mint magic links etc.) for integration tests.
        Environment.SetEnvironmentVariable("DOTBOT_TEST_MODE", "true");

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

            // Replace DI-blocking services with in-process test doubles.
            services.RemoveAll<ITemplateStorageService>();
            services.RemoveAll<IAdministratorService>();
            services.RemoveAll<IConversationReferenceStore>();
            services.RemoveAll<IInstanceStorageService>();
            services.RemoveAll<ITokenStorageService>();
            services.RemoveAll<Dotbot.Server.Services.Attachments.IAttachmentStorage>();

            services.AddSingleton<ITemplateStorageService>(TemplateStorage);
            services.AddSingleton<IAdministratorService>(new NullAdministratorService());
            services.AddSingleton<IConversationReferenceStore>(new NullConversationReferenceStore());
            services.AddSingleton<IInstanceStorageService>(InstanceStorage);
            services.AddSingleton<ITokenStorageService>(TokenStorage);
            services.AddSingleton<Dotbot.Server.Services.Attachments.IAttachmentStorage>(AttachmentStorage);
        });
    }
}
