using Dotbot.Server.Models;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Tests.Integration;

public class PostTemplatesTests : IntegrationTestBase
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    public PostTemplatesTests(DotbotApiFactory factory) : base(factory) { }

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

        var response = await Client.PostAsync("/api/templates", Json(template));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(Storage.Saved, t => t.QuestionId == template.QuestionId);
        var location = response.Headers.Location?.ToString();
        Assert.NotNull(location);
        Assert.Contains(template.QuestionId.ToString(), location);
    }

    [Fact]
    public async Task ValidApprovalWithAttachment_Returns201AndPersists()
    {
        var template = ValidApproval();

        var response = await Client.PostAsync("/api/templates", Json(template));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(Storage.Saved, t => t.QuestionId == template.QuestionId);
        var location = response.Headers.Location?.ToString();
        Assert.NotNull(location);
        Assert.Contains(template.QuestionId.ToString(), location);
    }

    [Fact]
    public async Task MultiFieldInvalidPayload_Returns400WithAllViolations()
    {
        // Payload triggers at least three known violations: empty questionId, empty projectId,
        // unknown type. Assertions check those are present and that returned errors are unique;
        // exact count is intentionally not asserted so new validator rules don't break this test.
        var payload = new
        {
            questionId = Guid.Empty,
            version = 1,
            title = "t",
            type = "bogus",
            options = Array.Empty<object>(),
            project = new { projectId = "" },
        };

        var response = await Client.PostAsync("/api/templates", Json(payload));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.NotNull(body?.Errors);
        Assert.Contains(body.Errors, e => e.Contains("questionId"));
        Assert.Contains(body.Errors, e => e.Contains("project.projectId"));
        Assert.Contains(body.Errors, e => e.Contains("bogus"));
        Assert.Equal(body.Errors.Length, body.Errors.Distinct().Count());
    }

    [Fact]
    public async Task MalformedJson_Returns400()
    {
        var content = new StringContent("{ not valid json }", Encoding.UTF8, "application/json");

        var response = await Client.PostAsync("/api/templates", content);
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

        var response = await Client.PostAsync("/api/templates", Json(payload));
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

        var response = await Client.PostAsync("/api/templates", Json(template));
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

        var response = await Client.PostAsync("/api/templates", Json(template));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains(body?.Errors ?? [], e => e.Contains("url"));
    }

    [Fact]
    public async Task AttachmentsOverCap_Returns400()
    {
        var template = ValidSingleChoice();
        template.Attachments = Enumerable.Range(0, DotbotApiFactory.TestMaxAttachments + 1)
            .Select(i => new QuestionAttachment
            {
                AttachmentId = Guid.NewGuid(),
                Name = $"doc{i}.pdf",
                Url = "https://docs.example.com/doc.pdf",
            })
            .ToList();

        var response = await Client.PostAsync("/api/templates", Json(template));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains(body?.Errors ?? [], e => e.Contains("attachments"));
    }

    [Fact]
    public async Task ReferenceLinksOverCap_Returns400()
    {
        var template = ValidSingleChoice();
        template.ReferenceLinks = Enumerable.Range(0, DotbotApiFactory.TestMaxReferenceLinks + 1)
            .Select(i => new ReferenceLink { Label = $"link{i}", Url = "https://docs.example.com/link" })
            .ToList();

        var response = await Client.PostAsync("/api/templates", Json(template));
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
