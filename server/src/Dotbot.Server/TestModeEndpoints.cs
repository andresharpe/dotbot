using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Microsoft.AspNetCore.WebUtilities;
using Serilog;
using System.Text.Json;

namespace Dotbot.Server;

public static class TestModeEndpoints
{
    private const string TestModeEnvVar = "DOTBOT_TEST_MODE";
    private const string LogCategory = "Dotbot.Server.TestModeEndpoints";

    public static void MapTestModeEndpoints(this WebApplication app)
    {
        if (!IsTestModeEnabled())
        {
            return;
        }

        Log.Warning("DOTBOT_TEST_MODE is enabled - /api/test/* endpoints are live. Do not run this in production.");

        MapInjectResponseEndpoint(app);
        MapMintMagicLinkEndpoint(app);
    }

    private static bool IsTestModeEnabled()
    {
        var value = Environment.GetEnvironmentVariable(TestModeEnvVar);
        return string.Equals(value, "true", StringComparison.OrdinalIgnoreCase);
    }

    private static void MapInjectResponseEndpoint(WebApplication app)
    {
        app.MapPost("/api/test/responses", async (
            HttpRequest request,
            AttachmentStorageService attachments,
            ResponseStorageService responses,
            ILoggerFactory loggerFactory) =>
        {
            var logger = loggerFactory.CreateLogger(LogCategory);
            TestResponseRequest? body;
            try
            {
                body = await request.ReadFromJsonAsync<TestResponseRequest>();
            }
            catch (JsonException ex)
            {
                return Results.BadRequest(new { error = "Invalid JSON: " + ex.Message });
            }

            if (body is null)
            {
                return Results.BadRequest(new { error = "Body is required" });
            }
            if (string.IsNullOrWhiteSpace(body.ProjectId))
            {
                return Results.BadRequest(new { error = "projectId is required" });
            }
            if (body.QuestionId == Guid.Empty)
            {
                return Results.BadRequest(new { error = "questionId is required" });
            }
            if (body.InstanceId == Guid.Empty)
            {
                return Results.BadRequest(new { error = "instanceId is required" });
            }
            if (string.IsNullOrWhiteSpace(body.SelectedKey)
                && string.IsNullOrWhiteSpace(body.FreeText)
                && (body.Attachments is null || body.Attachments.Count == 0))
            {
                return Results.BadRequest(new { error = "At least one of selectedKey, freeText, or attachments is required" });
            }

            var responseId = Guid.NewGuid();
            var attachmentRecords = new List<AttachmentRecord>();

            if (body.Attachments is not null)
            {
                foreach (var att in body.Attachments)
                {
                    if (string.IsNullOrWhiteSpace(att.Name) || string.IsNullOrWhiteSpace(att.ContentBase64))
                    {
                        return Results.BadRequest(new { error = "Each attachment requires name and contentBase64" });
                    }

                    byte[] bytes;
                    try
                    {
                        bytes = Convert.FromBase64String(att.ContentBase64);
                    }
                    catch (FormatException)
                    {
                        return Results.BadRequest(new { error = $"Attachment '{att.Name}' has invalid base64" });
                    }

                    using var ms = new MemoryStream(bytes);
                    var record = await attachments.SaveAsync(responseId, att.Name, ms, bytes.LongLength);
                    attachmentRecords.Add(record);
                }
            }

            var responseRecord = new ResponseRecordV2
            {
                ResponseId = responseId,
                InstanceId = body.InstanceId,
                QuestionId = body.QuestionId,
                QuestionVersion = body.QuestionVersion ?? 1,
                ProjectId = body.ProjectId,
                SelectedKey = string.IsNullOrWhiteSpace(body.SelectedKey) ? null : body.SelectedKey,
                FreeText = string.IsNullOrWhiteSpace(body.FreeText) ? null : body.FreeText,
                Attachments = attachmentRecords.Count > 0 ? attachmentRecords : null,
                ResponderEmail = body.ResponderEmail,
                ResponderAadObjectId = body.ResponderAadObjectId
            };

            await responses.SaveResponseAsync(responseRecord);

            logger.LogInformation("Test response injected: {ResponseId} for instance {InstanceId} with {AttachmentCount} attachment(s)",
                responseId, body.InstanceId, attachmentRecords.Count);

            return Results.Ok(new
            {
                responseId,
                attachments = attachmentRecords.Select(a => new { a.Name, a.SizeBytes, a.BlobPath })
            });
        });
    }

    private static void MapMintMagicLinkEndpoint(WebApplication app)
    {
        app.MapPost("/api/test/magic-link", async (
            HttpRequest request,
            MagicLinkService magicLinks,
            ILoggerFactory loggerFactory) =>
        {
            var logger = loggerFactory.CreateLogger(LogCategory);
            TestMagicLinkRequest? body;
            try
            {
                body = await request.ReadFromJsonAsync<TestMagicLinkRequest>();
            }
            catch (JsonException ex)
            {
                return Results.BadRequest(new { error = "Invalid JSON: " + ex.Message });
            }

            if (body is null)
            {
                return Results.BadRequest(new { error = "Body is required" });
            }
            if (string.IsNullOrWhiteSpace(body.ProjectId))
            {
                return Results.BadRequest(new { error = "projectId is required" });
            }
            if (body.InstanceId == Guid.Empty)
            {
                return Results.BadRequest(new { error = "instanceId is required" });
            }
            if (string.IsNullOrWhiteSpace(body.RecipientEmail))
            {
                return Results.BadRequest(new { error = "recipientEmail is required" });
            }

            var baseUrl = $"{request.Scheme}://{request.Host}";
            var url = await magicLinks.GenerateMagicLinkAsync(body.RecipientEmail, body.InstanceId, body.ProjectId, baseUrl);
            var token = QueryHelpers.ParseQuery(new Uri(url).Query)["token"].ToString();

            logger.LogInformation("Test magic link minted for {Email}, instance {InstanceId}", body.RecipientEmail, body.InstanceId);
            return Results.Ok(new { token, redemptionUrl = url });
        });
    }
}

internal record TestResponseRequest(
    string ProjectId,
    Guid QuestionId,
    Guid InstanceId,
    int? QuestionVersion,
    string? SelectedKey,
    string? FreeText,
    string? ResponderEmail,
    string? ResponderAadObjectId,
    List<TestResponseAttachment>? Attachments);

internal record TestResponseAttachment(string Name, string ContentBase64);

internal record TestMagicLinkRequest(string ProjectId, Guid InstanceId, string RecipientEmail);
