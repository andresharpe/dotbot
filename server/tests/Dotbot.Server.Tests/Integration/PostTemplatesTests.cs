using Dotbot.Server.Models;
using Dotbot.Server.Tests.Integration.TestDoubles;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Tests.Integration;

public class PostTemplatesTests : IClassFixture<TemplatesApiFactory>
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _client;
    private readonly InMemoryTemplateStorage _storage;

    public PostTemplatesTests(TemplatesApiFactory factory)
    {
        _client = factory.CreateClient();
        _client.DefaultRequestHeaders.Add("X-Api-Key", TemplatesApiFactory.TestApiKey);
        _storage = factory.Storage;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static QuestionTemplate ValidSingleChoice() => new()
    {
        QuestionId = Guid.NewGuid(),
        Version = 1,
        Title = "Which approach?",
        Type = QuestionTypes.SingleChoice,
        Options = [],
        Project = new ProjectRef { ProjectId = "proj-123" },
    };

    private static QuestionTemplate ValidApproval() => new()
    {
        QuestionId = Guid.NewGuid(),
        Version = 1,
        Title = "Approve the deliverable?",
        Type = QuestionTypes.Approval,
        DeliverableSummary = "Implementation complete per spec.",
        Options = [],
        Project = new ProjectRef { ProjectId = "proj-456" },
        Attachments =
        [
            new QuestionAttachment
            {
                AttachmentId = Guid.NewGuid(),
                Name = "spec.pdf",
                Url = "https://docs.example.com/spec.pdf",
            }
        ],
    };

    private static StringContent Json(object payload) =>
        new(JsonSerializer.Serialize(payload, JsonOpts), Encoding.UTF8, "application/json");

    // ── Scenarios ────────────────────────────────────────────────────────────

    [Fact]
    public async Task ValidSingleChoice_Returns201AndPersists()
    {
        var template = ValidSingleChoice();

        var response = await _client.PostAsync("/api/templates", Json(template));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(_storage.Saved, t => t.QuestionId == template.QuestionId);
        var location = response.Headers.Location?.ToString();
        Assert.NotNull(location);
        Assert.Contains(template.QuestionId.ToString(), location);
    }

    [Fact]
    public async Task ValidApprovalWithAttachment_Returns201AndPersists()
    {
        var template = ValidApproval();

        var response = await _client.PostAsync("/api/templates", Json(template));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(_storage.Saved, t => t.QuestionId == template.QuestionId);
        var location = response.Headers.Location?.ToString();
        Assert.NotNull(location);
        Assert.Contains(template.QuestionId.ToString(), location);
    }

    [Fact]
    public async Task MultiFieldInvalidPayload_Returns400WithAllViolations()
    {
        // Exactly three violations: empty questionId, empty projectId, unknown type.
        var payload = new
        {
            questionId = Guid.Empty,
            version = 1,
            title = "t",
            type = "bogus",
            options = Array.Empty<object>(),
            project = new { projectId = "" },
        };

        var response = await _client.PostAsync("/api/templates", Json(payload));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.NotNull(body?.Errors);
        Assert.Equal(3, body.Errors.Length);
        Assert.Contains(body.Errors, e => e.Contains("questionId"));
        Assert.Contains(body.Errors, e => e.Contains("project.projectId"));
        Assert.Contains(body.Errors, e => e.Contains("bogus"));
    }

    [Fact]
    public async Task MalformedJson_Returns400()
    {
        var content = new StringContent("{ not valid json }", Encoding.UTF8, "application/json");

        var response = await _client.PostAsync("/api/templates", content);
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.NotNull(body?.Error);
        Assert.NotNull(body?.Errors);
    }

    [Fact]
    public async Task NullProject_Returns400()
    {
        // Regression: validator must not throw NRE when project is null (commit 7aac214).
        var payload = new
        {
            questionId = Guid.NewGuid(),
            version = 1,
            title = "t",
            type = QuestionTypes.SingleChoice,
            options = Array.Empty<object>(),
            project = (object?)null,
        };

        var response = await _client.PostAsync("/api/templates", Json(payload));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.NotNull(body?.Error);
        Assert.Contains(body.Errors ?? [], e => e.Contains("project.projectId"));
    }

    [Theory]
    [InlineData("projects/../secrets/config")]
    [InlineData("./relative/path")]
    [InlineData("/absolute/path")]
    [InlineData("path\\with\\backslash")]
    public async Task BlobPathTraversal_Returns400(string blobPath)
    {
        var template = ValidSingleChoice();
        template.Attachments =
        [
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "file.pdf", BlobPath = blobPath }
        ];

        var response = await _client.PostAsync("/api/templates", Json(template));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains(body?.Errors ?? [], e => e.Contains("blobPath"));
    }

    [Theory]
    [InlineData("http://example.com/doc")]          // non-HTTPS scheme
    [InlineData("https://user:pass@example.com/")]  // UserInfo present
    [InlineData("https://127.0.0.1/doc")]            // loopback IP
    [InlineData("https://localhost/doc")]             // loopback hostname
    [InlineData("https://169.254.169.254/metadata")] // link-local / IMDS
    public async Task UnsafeAttachmentUrl_Returns400(string unsafeUrl)
    {
        var template = ValidSingleChoice();
        template.Attachments =
        [
            new QuestionAttachment { AttachmentId = Guid.NewGuid(), Name = "file.pdf", Url = unsafeUrl }
        ];

        var response = await _client.PostAsync("/api/templates", Json(template));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains(body?.Errors ?? [], e => e.Contains("url"));
    }

    [Fact]
    public async Task AttachmentsOverCap_Returns400()
    {
        var template = ValidSingleChoice();
        template.Attachments = Enumerable.Range(0, QuestionTemplateValidationSettings.DefaultMaxAttachments + 1)
            .Select(i => new QuestionAttachment
            {
                AttachmentId = Guid.NewGuid(),
                Name = $"doc{i}.pdf",
                Url = "https://docs.example.com/doc.pdf",
            })
            .ToList();

        var response = await _client.PostAsync("/api/templates", Json(template));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains(body?.Errors ?? [], e => e.Contains("attachments"));
    }

    [Fact]
    public async Task ReferenceLinksOverCap_Returns400()
    {
        var template = ValidSingleChoice();
        template.ReferenceLinks = Enumerable.Range(0, QuestionTemplateValidationSettings.DefaultMaxReferenceLinks + 1)
            .Select(i => new ReferenceLink { Label = $"link{i}", Url = "https://docs.example.com/link" })
            .ToList();

        var response = await _client.PostAsync("/api/templates", Json(template));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains(body?.Errors ?? [], e => e.Contains("referenceLinks"));
    }

    // ── Response shape ───────────────────────────────────────────────────────

    private sealed class ErrorResponse
    {
        public string? Error { get; set; }
        public string[]? Errors { get; set; }
    }
}
