using Azure.Identity;
using Azure.Storage.Blobs;
using Dotbot.Server;
using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Dotbot.Server.Services.Delivery;
using Dotbot.Server.Validation;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.Identity.Web;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Serilog;
using Serilog.Sinks.ApplicationInsights.TelemetryConverters;
using System.Security.Claims;
using System.Text.Json;

// ── Bootstrap logger (captures startup errors before host is built) ─────────
var loggerConfig = new LoggerConfiguration()
    .MinimumLevel.Information()
    .Enrich.WithProperty("Application", "Dotbot.Server")
    .WriteTo.Console();

var environmentName = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production";
loggerConfig.Enrich.WithProperty("Environment", environmentName);

// Add Application Insights sink early if connection string is available
var appInsightsConnectionString = Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING");
if (!string.IsNullOrEmpty(appInsightsConnectionString))
{
    loggerConfig.WriteTo.ApplicationInsights(
        connectionString: appInsightsConnectionString,
        telemetryConverter: new TraceTelemetryConverter());
}

if (environmentName == "Development")
{
    var logPath = Path.Combine("..", "..", "logs", "dotbot-.log");
    loggerConfig.WriteTo.File(
        path: logPath,
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: 30,
        outputTemplate: "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}");
}

Log.Logger = loggerConfig.CreateLogger();

try
{
    Log.Information("Starting Dotbot.Server");

    var builder = WebApplication.CreateBuilder(args);

    // Clear default logging and wire Serilog
    builder.Logging.ClearProviders();
    builder.Host.UseSerilog();

    // ── Application Insights SDK ────────────────────────────────────────────
    if (!string.IsNullOrEmpty(appInsightsConnectionString))
    {
        builder.Services.AddApplicationInsightsTelemetry(options =>
        {
            options.ConnectionString = appInsightsConnectionString;
        });
        Log.Information("Application Insights telemetry enabled");
    }

    // ── Startup configuration dump (redacted) ───────────────────────────────
    LogStartupConfiguration(builder);

    // ── M365 Agents SDK setup ───────────────────────────────────────────────
    builder.Services.AddHttpClient();
    builder.AddAgentApplicationOptions();
    builder.AddAgent<DotbotAgent>();
    builder.Services.AddSingleton<IStorage, MemoryStorage>();

    // Azure Blob Storage — Managed Identity in production, connection string fallback for local dev
    var blobAccountUri = builder.Configuration["BlobStorage:AccountUri"];
    var blobConnectionString = builder.Configuration["BlobStorage:ConnectionString"];
    if (!string.IsNullOrEmpty(blobAccountUri))
    {
        builder.Services.AddSingleton(new BlobServiceClient(new Uri(blobAccountUri), new DefaultAzureCredential()));
    }
    else if (!string.IsNullOrEmpty(blobConnectionString))
    {
        builder.Services.AddSingleton(new BlobServiceClient(blobConnectionString));
    }
    else
    {
        throw new InvalidOperationException("Either BlobStorage:AccountUri or BlobStorage:ConnectionString must be configured");
    }

    // Configuration bindings
    builder.Services.Configure<AuthSettings>(builder.Configuration.GetSection("Auth"));
    builder.Services.Configure<DeliveryChannelSettings>(builder.Configuration.GetSection("DeliveryChannels"));
    builder.Services.Configure<BusinessHoursSettings>(builder.Configuration.GetSection("BusinessHours"));
    builder.Services.Configure<QuestionTemplateValidationSettings>(
        builder.Configuration.GetSection("Validation:QuestionTemplate"));

    // Core application services
    builder.Services.AddSingleton<StoragePathResolver>();
    builder.Services.AddSingleton<TemplateStorageService>();
    builder.Services.AddSingleton<QuestionTemplateValidator>();
    builder.Services.AddSingleton<InstanceStorageService>();
    builder.Services.AddSingleton<ResponseStorageService>();
    builder.Services.AddSingleton<AttachmentStorageService>();
    builder.Services.AddSingleton<ConversationReferenceStore>();
    builder.Services.AddSingleton<AdaptiveCardService>();

    // Auth services
    builder.Services.AddSingleton<GraphTokenService>();
    builder.Services.AddSingleton<UserResolverService>();
    builder.Services.AddSingleton<BusinessHoursService>();
    builder.Services.AddSingleton<JwtSigningKeyProvider>();
    builder.Services.AddSingleton<TokenStorageService>();
    builder.Services.AddSingleton<MagicLinkService>();
    builder.Services.AddSingleton<NotificationSummaryBuilder>();

    // Delivery providers
    builder.Services.AddSingleton<IQuestionDeliveryProvider, TeamsDeliveryProvider>();

    var emailEnabled = builder.Configuration.GetValue<bool>("DeliveryChannels:Email:Enabled");
    if (emailEnabled)
    {
        builder.Services.AddSingleton<IQuestionDeliveryProvider, EmailDeliveryProvider>();
    }

    var jiraEnabled = builder.Configuration.GetValue<bool>("DeliveryChannels:Jira:Enabled");
    if (jiraEnabled)
    {
        builder.Services.AddSingleton<IQuestionDeliveryProvider, JiraDeliveryProvider>();
    }

    var slackEnabled = builder.Configuration.GetValue<bool>("DeliveryChannels:Slack:Enabled");
    if (slackEnabled)
    {
        builder.Services.AddSingleton<IQuestionDeliveryProvider, SlackDeliveryProvider>();
    }

    builder.Services.AddSingleton<DeliveryOrchestrator>();

    // Reminder/escalation background service
    builder.Services.AddHostedService<ReminderEscalationService>();

    // Razor Pages for web response UI
    builder.Services.AddRazorPages();

    // Administrator service
    builder.Services.AddSingleton<AdministratorService>();

    // Azure AD authentication for dashboard (reuses bot app registration)
    if (environmentName != "Development")
    {
        builder.Services.AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
            .AddMicrosoftIdentityWebApp(options =>
            {
                options.Instance = "https://login.microsoftonline.com/";
                options.TenantId = builder.Configuration["MicrosoftAppTenantId"];
                options.ClientId = builder.Configuration["MicrosoftAppId"];
                options.ClientSecret = builder.Configuration["MicrosoftAppPassword"]; // noscan
                options.CallbackPath = "/signin-oidc";
                options.ResponseType = OpenIdConnectResponseType.Code;
                options.Scope.Clear();
                options.Scope.Add("openid");
                options.Scope.Add("profile");
                options.Scope.Add("email");
            });
    }
    builder.Services.AddAuthorization();

    var app = builder.Build();

    // ── Middleware pipeline ──────────────────────────────────────────────────
    app.UseSerilogRequestLogging();
    app.UseMiddleware<ApiKeyMiddleware>();
    app.UseMiddleware<MagicLinkAuthMiddleware>();

    app.UseStaticFiles();
    app.UseRouting();

    // Auth middleware pipeline
    if (environmentName == "Development")
    {
        app.UseMiddleware<DevelopmentAuthMiddleware>();
    }
    app.UseAuthentication();
    app.UseAuthorization();
    app.UseMiddleware<DashboardAuthMiddleware>();

    // Seed administrator list
    var adminService = app.Services.GetRequiredService<AdministratorService>();
    await adminService.SeedIfEmptyAsync();

    // Load persisted conversation references into memory cache
    var convoStore = app.Services.GetRequiredService<ConversationReferenceStore>();
    await convoStore.LoadAsync();
    Log.Information("Conversation references loaded into memory cache");

    // Razor Pages
    app.MapRazorPages();

    // ── Bot messaging endpoint ──────────────────────────────────────────────
    app.MapPost("/api/messages", async (HttpRequest request, HttpResponse response,
        IAgentHttpAdapter adapter, IAgent agent, CancellationToken ct) =>
    {
        await adapter.ProcessAsync(request, response, agent, ct);
    });

    // ── v1: Publish a question template ─────────────────────────────────────
    app.MapPost("/api/templates", async (HttpRequest request, TemplateStorageService templates, QuestionTemplateValidator validator, ILogger<Program> logger) =>
    {
        QuestionTemplate? template;
        try
        {
            template = await request.ReadFromJsonAsync<QuestionTemplate>();
        }
        catch (JsonException ex)
        {
            logger.LogWarning("Template publish rejected: malformed JSON: {Message}", ex.Message);
            return Results.BadRequest(new { error = "Invalid JSON payload", errors = new[] { "Invalid JSON payload", ex.Message } });
        }
        if (template is null)
        {
            logger.LogWarning("Template publish rejected: invalid JSON payload");
            return Results.BadRequest(new { error = "Invalid JSON payload", errors = new[] { "Invalid JSON payload" } });
        }
        var errors = validator.Validate(template);
        if (errors.Count > 0)
        {
            logger.LogWarning("Template publish rejected: {Reasons}", string.Join("; ", errors));
            return Results.BadRequest(new { error = errors[0], errors });
        }
        await templates.SaveTemplateAsync(template);
        logger.LogInformation("Template published: {QuestionId} v{Version} for project {ProjectId}",
            template.QuestionId, template.Version, template.Project.ProjectId);
        return Results.Created($"/api/templates/{template.Project.ProjectId}/{template.QuestionId}/v{template.Version}", new { template.QuestionId, template.Version });
    });

    // ── v1: Create an instance and fan-out to recipients ────────────────────
    app.MapPost("/api/instances", async (
        HttpRequest request,
        TemplateStorageService templates,
        InstanceStorageService instances,
        DeliveryOrchestrator orchestrator,
        ILogger<Program> logger,
        CancellationToken ct) =>
    {
        var req = await request.ReadFromJsonAsync<CreateInstanceRequest>();
        if (req is null)
        {
            logger.LogWarning("Instance creation rejected: invalid JSON");
            return Results.BadRequest(new { error = "Invalid JSON" });
        }
        if (req.QuestionId == Guid.Empty)
        {
            logger.LogWarning("Instance creation rejected: questionId must be a GUID");
            return Results.BadRequest(new { error = "questionId must be a GUID" });
        }
        if (req.InstanceId == Guid.Empty) req.InstanceId = Guid.NewGuid();

        var channel = req.Channel ?? "teams";
        if (!orchestrator.IsChannelAvailable(channel))
        {
            logger.LogWarning("Instance creation rejected: delivery channel '{Channel}' is not enabled. Available: {Available}",
                channel, string.Join(", ", orchestrator.AvailableChannels));
            return Results.BadRequest(new { error = $"Delivery channel '{channel}' is not enabled. Available channels: {string.Join(", ", orchestrator.AvailableChannels)}" });
        }

        if (req.Channel == "jira" && string.IsNullOrEmpty(req.JiraIssueKey))
        {
            logger.LogWarning("Instance creation rejected: jiraIssueKey required for jira channel");
            return Results.BadRequest(new { error = "jiraIssueKey is required when channel is 'jira'" });
        }

        // Validate recipients
        var allEmails = req.Recipients?.Emails ?? [];
        var allObjectIds = req.Recipients?.UserObjectIds ?? [];
        var allSlackUserIds = req.Recipients?.SlackUserIds ?? [];
        if (allEmails.Count == 0 && allObjectIds.Count == 0 && allSlackUserIds.Count == 0)
        {
            logger.LogWarning("Instance creation rejected: no recipients specified");
            return Results.BadRequest(new { error = "At least one email, userObjectId, or slackUserId is required in recipients" });
        }

        var invalidEmails = allEmails
            .Where(e => string.IsNullOrWhiteSpace(e) || !System.Text.RegularExpressions.Regex.IsMatch(e, @"^[^@\s]+@[^@\s]+\.[^@\s]+$"))
            .ToList();
        if (invalidEmails.Count > 0)
        {
            logger.LogWarning("Instance creation rejected: invalid emails {InvalidEmails}", invalidEmails);
            return Results.BadRequest(new { error = $"Invalid email address(es): {string.Join(", ", invalidEmails)}" });
        }

        var template = await templates.GetTemplateAsync(req.ProjectId, req.QuestionId, req.QuestionVersion);
        if (template is null)
        {
            logger.LogWarning("Instance creation failed: template not found for {ProjectId}/{QuestionId}/v{Version}",
                req.ProjectId, req.QuestionId, req.QuestionVersion);
            return Results.NotFound(new { error = "Template not found" });
        }

        var instance = new QuestionInstance
        {
            InstanceId = req.InstanceId,
            QuestionId = req.QuestionId,
            QuestionVersion = req.QuestionVersion,
            ProjectId = req.ProjectId,
            CreatedBy = req.CreatedBy,
            DeliveryOverrides = req.DeliveryOverrides
        };

        var sent = await orchestrator.DeliverToAllAsync(instance, template, req, ct);
        instance.SentTo = sent;
        await instances.SaveInstanceAsync(instance);

        logger.LogInformation("Instance created: {InstanceId} for question {QuestionId}, channel {Channel}, {RecipientCount} recipient(s)",
            req.InstanceId, req.QuestionId, req.Channel ?? "teams", sent.Count);
        return Results.Ok(new { instanceId = req.InstanceId, recipients = sent });
    });

    // ── v1: Get instance ────────────────────────────────────────────────────
    app.MapGet("/api/instances/{projectId}/{instanceId}", async (string projectId, Guid instanceId, InstanceStorageService instances) =>
    {
        var inst = await instances.GetInstanceAsync(projectId, instanceId);
        return inst is not null ? Results.Ok(inst) : Results.NotFound();
    });

    // ── v1: List responses for an instance ──────────────────────────────────
    app.MapGet("/api/instances/{projectId}/{questionId}/{instanceId}/responses", async (
        string projectId, Guid questionId, Guid instanceId,
        ResponseStorageService responses, ILogger<Program> logger) =>
    {
        var list = new List<ResponseRecordV2>();
        await foreach (var r in responses.ListResponsesAsync(projectId, questionId, instanceId))
            list.Add(r);
        logger.LogInformation("Listed {Count} response(s) for instance {InstanceId}", list.Count, instanceId);
        return Results.Ok(list.OrderBy(r => r.SubmittedAt));
    });

    // ── Download attachment by blob path (API key protected) ────────────────
    app.MapGet("/api/attachments/{**blobPath}", async (
        string blobPath,
        AttachmentStorageService attachments,
        ILogger<Program> logger) =>
    {
        var result = await attachments.DownloadAsync(blobPath);
        if (result is null) return Results.NotFound();
        var (stream, contentType) = result.Value;
        var fileName = Path.GetFileName(blobPath);
        return Results.File(stream, contentType, fileName);
    });

    app.MapTestModeEndpoints();

    // ── Revoke a device token (API key protected) ───────────────────────────
    app.MapPost("/tokens/revoke", async (HttpRequest request, TokenStorageService tokenStorage, ILogger<Program> logger) =>
    {
        var body = await request.ReadFromJsonAsync<RevokeTokenRequest>();
        if (body is null || string.IsNullOrEmpty(body.DeviceTokenId))
        {
            logger.LogWarning("Token revocation rejected: deviceTokenId is required");
            return Results.BadRequest(new { error = "deviceTokenId is required" });
        }

        var revoked = await tokenStorage.RevokeDeviceTokenAsync(body.DeviceTokenId);
        if (revoked)
            logger.LogInformation("Device token revoked: {DeviceTokenId}", body.DeviceTokenId);
        else
            logger.LogWarning("Device token revocation failed: not found or already revoked {DeviceTokenId}", body.DeviceTokenId);

        return revoked
            ? Results.Ok(new { revoked = true })
            : Results.NotFound(new { error = "Token not found or already revoked" });
    });

    // ── Dashboard API endpoints ────────────────────────────────────────────
    app.MapGet("/api/dashboard/instances", async (
        InstanceStorageService instances,
        TemplateStorageService templates,
        ResponseStorageService responses,
        ILogger<Program> logger) =>
    {
        var templateCache = new Dictionary<string, QuestionTemplate?>();
        var responseCache = new Dictionary<string, List<ResponseRecordV2>>();
        var result = new List<object>();

        await foreach (var instance in instances.ListAllInstancesAsync())
        {
            // Load template (cached by key to avoid N+1)
            var templateKey = $"{instance.ProjectId}/{instance.QuestionId}/v{instance.QuestionVersion}";
            if (!templateCache.TryGetValue(templateKey, out var template))
            {
                template = await templates.GetTemplateAsync(instance.ProjectId, instance.QuestionId, instance.QuestionVersion);
                templateCache[templateKey] = template;
            }

            // Load all responses for this question across all instance IDs (cached per question)
            var questionKey = $"{instance.ProjectId}/{instance.QuestionId}";
            if (!responseCache.TryGetValue(questionKey, out var questionResponses))
            {
                questionResponses = new List<ResponseRecordV2>();
                await foreach (var r in responses.ListResponsesForQuestionAsync(instance.ProjectId, instance.QuestionId))
                    questionResponses.Add(r);
                responseCache[questionKey] = questionResponses;
            }

            var recipientData = instance.SentTo.Select(r =>
            {
                var response = questionResponses.FirstOrDefault(resp =>
                    (!string.IsNullOrEmpty(resp.ResponderAadObjectId) && !string.IsNullOrEmpty(r.AadObjectId)
                        && string.Equals(resp.ResponderAadObjectId, r.AadObjectId, StringComparison.OrdinalIgnoreCase))
                    || (!string.IsNullOrEmpty(resp.ResponderEmail) && !string.IsNullOrEmpty(r.Email)
                        && string.Equals(resp.ResponderEmail, r.Email, StringComparison.OrdinalIgnoreCase))
                    || (!string.IsNullOrEmpty(resp.ResponderEmail) && !string.IsNullOrEmpty(r.SlackUserId)
                        && string.Equals(resp.ResponderEmail, r.SlackUserId, StringComparison.OrdinalIgnoreCase)));

                return new
                {
                    email = r.Email ?? r.SlackUserId,
                    aadObjectId = r.AadObjectId,
                    channel = r.Channel,
                    status = r.Status,
                    sentAt = r.SentAt,
                    lastReminderAt = r.LastReminderAt,
                    escalatedAt = r.EscalatedAt,
                    hasResponse = response is not null,
                    selectedOption = response?.SelectedOptionTitle
                };
            }).ToList();

            // If sentTo is empty but responses exist, synthesize recipients from responses
            if (recipientData.Count == 0)
            {
                var instanceResponses = questionResponses
                    .Where(r => r.InstanceId == instance.InstanceId)
                    .ToList();
                foreach (var resp in instanceResponses)
                {
                    recipientData.Add(new
                    {
                        email = resp.ResponderEmail,
                        aadObjectId = resp.ResponderAadObjectId,
                        channel = "teams",
                        status = "sent",
                        sentAt = (DateTime?)instance.CreatedAt,
                        lastReminderAt = (DateTime?)null,
                        escalatedAt = (DateTime?)null,
                        hasResponse = true,
                        selectedOption = resp.SelectedOptionTitle
                    });
                }
            }

            var totalRecipients = recipientData.Count > 0 ? recipientData.Count : instance.SentTo.Count;

            result.Add(new
            {
                instanceId = instance.InstanceId,
                questionId = instance.QuestionId,
                questionVersion = instance.QuestionVersion,
                questionTitle = template?.Title ?? "(unknown)",
                templateDescription = template?.Description,
                templateContext = template?.Context,
                templateOptions = template?.Options?.Select(o => new { o.OptionId, o.Key, o.Title, o.Summary, o.IsRecommended }),
                projectId = instance.ProjectId,
                projectName = template?.Project?.Name ?? instance.ProjectId,
                createdAt = instance.CreatedAt,
                createdBy = instance.CreatedBy,
                overallStatus = instance.OverallStatus,
                recipients = recipientData,
                totalRecipients,
                respondedCount = recipientData.Count(r => r.hasResponse),
                responseDetails = questionResponses.Select(r => new { r.ResponderEmail, r.ResponderAadObjectId, r.SelectedOptionTitle, r.SelectedKey, r.FreeText, r.SubmittedAt })
            });
        }

        return Results.Ok(result);
    });

    app.MapDelete("/api/dashboard/instances/{projectId}/{instanceId}", async (
        string projectId, Guid instanceId,
        InstanceStorageService instances,
        ResponseStorageService responses,
        ILogger<Program> logger) =>
    {
        var instance = await instances.GetInstanceAsync(projectId, instanceId);
        if (instance is null)
            return Results.NotFound(new { error = "Instance not found" });

        var responsesDeleted = await responses.DeleteResponsesForInstanceAsync(projectId, instance.QuestionId, instanceId);
        await instances.DeleteInstanceAsync(projectId, instanceId);

        logger.LogInformation("Instance {InstanceId} deleted from project {ProjectId}, {ResponsesDeleted} response(s) removed",
            instanceId, projectId, responsesDeleted);
        return Results.Ok(new { deleted = true, responsesDeleted });
    });

    app.MapPost("/api/dashboard/nudge", async (
        HttpRequest request,
        InstanceStorageService instances,
        TemplateStorageService templates,
        DeliveryOrchestrator orchestrator,
        ILogger<Program> logger,
        CancellationToken ct) =>
    {
        var body = await request.ReadFromJsonAsync<NudgeRequest>();
        if (body is null || string.IsNullOrEmpty(body.InstanceId) || string.IsNullOrEmpty(body.ProjectId) || string.IsNullOrEmpty(body.RecipientEmail))
            return Results.BadRequest(new { error = "projectId, instanceId, and recipientEmail are required" });

        if (!Guid.TryParse(body.InstanceId, out var instanceId))
            return Results.BadRequest(new { error = "instanceId must be a valid GUID" });

        var instance = await instances.GetInstanceAsync(body.ProjectId, instanceId);
        if (instance is null)
            return Results.NotFound(new { error = "Instance not found" });

        var recipient = instance.SentTo.FirstOrDefault(r =>
            string.Equals(r.Email, body.RecipientEmail, StringComparison.OrdinalIgnoreCase));
        if (recipient is null)
            return Results.NotFound(new { error = "Recipient not found in instance" });

        if (recipient.Status is not ("sent" or "reminded" or "scheduled"))
            return Results.BadRequest(new { error = $"Cannot nudge recipient with status '{recipient.Status}'" });

        var template = await templates.GetTemplateAsync(instance.ProjectId, instance.QuestionId, instance.QuestionVersion);
        if (template is null)
            return Results.NotFound(new { error = "Template not found" });

        var deliveryResult = await orchestrator.DeliverReminderAsync(instance, template, recipient, ct);

        if (deliveryResult.Success)
        {
            recipient.LastReminderAt = DateTime.UtcNow;
            recipient.Status = "reminded";
            await instances.SaveInstanceAsync(instance);
            logger.LogInformation("Manual nudge delivered to {Email} for instance {InstanceId}", body.RecipientEmail, instanceId);
            return Results.Ok(new { success = true });
        }

        logger.LogWarning("Manual nudge failed for {Email} on instance {InstanceId}: {Error}",
            body.RecipientEmail, instanceId, deliveryResult.ErrorMessage ?? deliveryResult.Channel);
        return Results.Ok(new { success = false, reason = deliveryResult.ErrorMessage ?? deliveryResult.Channel });
    });

    app.MapGet("/api/dashboard/signout", async (HttpContext context) =>
    {
        await context.SignOutAsync();
        context.Response.Redirect("/");
    });

    // Health check endpoint
    app.MapGet("/api/health", () => Results.Ok(new { status = "healthy", timestamp = DateTime.UtcNow }));

    Log.Information("Application started successfully");
    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "Application terminated unexpectedly");
    throw;
}
finally
{
    Log.Information("Application shutting down");
    Log.CloseAndFlush();
}

// ── Startup configuration logging (redacted secrets) ────────────────────────
static void LogStartupConfiguration(WebApplicationBuilder builder)
{
    var config = builder.Configuration;

    Log.Information("========================================");
    Log.Information("DOTBOT TEAMSBOT CONFIGURATION");
    Log.Information("========================================");

    // Environment
    Log.Information("[ENVIRONMENT]");
    Log.Information("  ASPNETCORE_ENVIRONMENT: {Environment}",
        Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "(not set)");
    Log.Information("  DOTNET_ENVIRONMENT: {DotnetEnv}",
        Environment.GetEnvironmentVariable("DOTNET_ENVIRONMENT") ?? "(not set)");
    Log.Information("  WEBSITE_HOSTNAME: {Hostname}",
        Environment.GetEnvironmentVariable("WEBSITE_HOSTNAME") ?? "(not set / local)");
    Log.Information("");

    // Bot Framework
    Log.Information("[BOT FRAMEWORK]");
    var appType = config["MicrosoftAppType"];
    var appId = config["MicrosoftAppId"];
    var tenantId = config["MicrosoftAppTenantId"];
    var hasPassword = !string.IsNullOrEmpty(config["MicrosoftAppPassword"]); // noscan
    Log.Information("  AppType: {AppType}", appType ?? "(not set)");
    Log.Information("  AppId: {AppId}", string.IsNullOrEmpty(appId) ? "(not set)" : appId);
    Log.Information("  TenantId: {TenantId}", string.IsNullOrEmpty(tenantId) ? "(not set)" : tenantId);
    Log.Information("  Password: {HasPassword}", hasPassword ? "SET" : "(not set)"); // noscan
    Log.Information("");

    // Blob Storage
    Log.Information("[BLOB STORAGE]");
    var blobUri = config["BlobStorage:AccountUri"];
    var blobConn = config["BlobStorage:ConnectionString"];
    Log.Information("  AccountUri: {AccountUri}", string.IsNullOrEmpty(blobUri) ? "(not set)" : blobUri);
    Log.Information("  ConnectionString: {HasConnString}", string.IsNullOrEmpty(blobConn) ? "(not set)" : "SET");
    Log.Information("");

    // Auth
    Log.Information("[AUTH]");
    Log.Information("  KeyVaultUri: {KeyVaultUri}", config["Auth:KeyVaultUri"] ?? "(not set)");
    Log.Information("  KeyName: {KeyName}", config["Auth:KeyName"] ?? "(not set)");
    Log.Information("  JwtSigningKey: {HasKey}", string.IsNullOrEmpty(config["Auth:JwtSigningKey"]) ? "(not set)" : "SET");
    Log.Information("  JwtIssuer: {Issuer}", config["Auth:JwtIssuer"] ?? "(not set)");
    Log.Information("  JwtAudience: {Audience}", config["Auth:JwtAudience"] ?? "(not set)");
    Log.Information("  MagicLinkExpiryMinutes: {Expiry}", config["Auth:MagicLinkExpiryMinutes"] ?? "(not set)");
    Log.Information("  DeviceTokenExpiryDays: {Expiry}", config["Auth:DeviceTokenExpiryDays"] ?? "(not set)");
    Log.Information("");

    // API Security
    Log.Information("[API SECURITY]");
    Log.Information("  ApiKey: {HasApiKey}", string.IsNullOrEmpty(config["ApiSecurity:ApiKey"]) ? "(not set)" : "SET");
    Log.Information("");

    // Delivery Channels
    Log.Information("[DELIVERY CHANNELS]");
    Log.Information("  Email Enabled: {EmailEnabled}", config["DeliveryChannels:Email:Enabled"] ?? "false");
    Log.Information("  Email Sender: {Sender}", config["DeliveryChannels:Email:SenderAddress"] ?? "(not set)");
    Log.Information("  Jira Enabled: {JiraEnabled}", config["DeliveryChannels:Jira:Enabled"] ?? "false");
    Log.Information("  Jira BaseUrl: {BaseUrl}", config["DeliveryChannels:Jira:BaseUrl"] ?? "(not set)");
    Log.Information("  Jira ApiToken: {HasToken}", string.IsNullOrEmpty(config["DeliveryChannels:Jira:ApiToken"]) ? "(not set)" : "SET");
    Log.Information("");

    // Reminders
    Log.Information("[REMINDERS]");
    Log.Information("  ReminderAfterHours: {Hours}", config["Reminders:DefaultReminderAfterHours"] ?? "(not set)");
    Log.Information("  EscalateAfterDays: {Days}", config["Reminders:DefaultEscalateAfterDays"] ?? "(not set)");
    Log.Information("  IntervalMinutes: {Interval}", config["Reminders:IntervalMinutes"] ?? "(not set)");

    // Business Hours
    Log.Information("");
    Log.Information("[BUSINESS HOURS]");
    Log.Information("  Enabled: {Enabled}", config["BusinessHours:Enabled"] ?? "false");
    Log.Information("  Window: {Start}-{End}",
        config["BusinessHours:StartHour"] ?? "8", config["BusinessHours:EndHour"] ?? "18");
    Log.Information("  ExemptChannels: {Channels}", config["BusinessHours:ExemptChannels"] ?? "(none)");
    Log.Information("  FallbackTimeZone: {Tz}", config["BusinessHours:FallbackTimeZone"] ?? "UTC");
    Log.Information("  FallbackCountryCode: {Country}", config["BusinessHours:FallbackCountryCode"] ?? "GB");

    // Validation
    Log.Information("");
    Log.Information("[VALIDATION]");
    Log.Information("  QuestionTemplate.MaxAttachments: {Max}",
        config["Validation:QuestionTemplate:MaxAttachments"] ?? QuestionTemplateValidationSettings.DefaultMaxAttachments.ToString());
    Log.Information("  QuestionTemplate.MaxReferenceLinks: {Max}",
        config["Validation:QuestionTemplate:MaxReferenceLinks"] ?? QuestionTemplateValidationSettings.DefaultMaxReferenceLinks.ToString());

    // Application Insights
    Log.Information("");
    Log.Information("[OBSERVABILITY]");
    var aiConn = Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING");
    Log.Information("  ApplicationInsights: {Status}", string.IsNullOrEmpty(aiConn) ? "(not configured)" : "ENABLED");

    Log.Information("========================================");
}

// Request models for minimal API endpoints
record RevokeTokenRequest(string DeviceTokenId);
record NudgeRequest(string ProjectId, string InstanceId, string RecipientEmail);
