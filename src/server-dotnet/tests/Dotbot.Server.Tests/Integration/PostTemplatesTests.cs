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
        Options =
        [
            new TemplateOption { OptionId = Guid.NewGuid(), Key = "a", Title = "Option A" },
            new TemplateOption { OptionId = Guid.NewGuid(), Key = "b", Title = "Option B" },
        ],
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

    // A valid envelope for a template publish (outpostInstanceId + taskId present).
    private static object Env() => new
    {
        outpostInstanceId = Guid.NewGuid(),
        taskId = "task-abc",
        mothershipUrl = "https://m.example.com",
        questionInstanceId = Guid.Empty,
        projectId = "proj-123",
    };

    private static StringContent Json(object payload) =>
        new(JsonSerializer.Serialize(payload, JsonOpts), Encoding.UTF8, "application/json");

    // Wraps a question in the SPEC-029 { envelope, question } publish shape.
    private static StringContent Wrap(object question, object? envelope = null) =>
        Json(new { envelope = envelope ?? Env(), question });

    // ── Scenarios ────────────────────────────────────────────────────────────

    [Fact]
    public async Task ValidSingleChoice_Returns201AndPersists()
    {
        var template = ValidSingleChoice();

        var response = await Client.PostAsync("/api/templates", Wrap(template));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(Factory.TemplateStorage.Saved, t => t.QuestionId == template.QuestionId);
        var location = response.Headers.Location?.ToString();
        Assert.NotNull(location);
        Assert.Contains(template.QuestionId.ToString(), location);
        Assert.Contains($"v{template.Version}", location); // version segment kept
    }

    [Fact]
    public async Task ValidApprovalWithAttachment_Returns201AndPersists()
    {
        var template = ValidApproval();

        var response = await Client.PostAsync("/api/templates", Wrap(template));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Single(Factory.TemplateStorage.Saved, t => t.QuestionId == template.QuestionId);
        var location = response.Headers.Location?.ToString();
        Assert.NotNull(location);
        Assert.Contains(template.QuestionId.ToString(), location);
    }

    [Fact]
    public async Task OutpostInstanceIdMissing_Returns400()
    {
        var envelope = new { outpostInstanceId = Guid.Empty, taskId = "task-abc" };
        var response = await Client.PostAsync("/api/templates", Wrap(ValidSingleChoice(), envelope));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("outpost_instance_id_required", body?.Error);
    }

    [Fact]
    public async Task TaskIdMissing_Returns400()
    {
        var envelope = new { outpostInstanceId = Guid.NewGuid(), taskId = "" };
        var response = await Client.PostAsync("/api/templates", Wrap(ValidSingleChoice(), envelope));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("task_id_required", body?.Error);
    }

    [Fact]
    public async Task InvalidQuestionType_Returns400()
    {
        var question = new
        {
            questionId = Guid.NewGuid(),
            version = 1,
            title = "t",
            type = "bogus",
            options = Array.Empty<object>(),
            project = new { projectId = "proj-123" },
        };

        var response = await Client.PostAsync("/api/templates", Wrap(question));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("invalid_question_type", body?.Error);
    }

    [Fact]
    public async Task SingleChoiceWithoutOptions_Returns400OptionsRequired()
    {
        var question = new
        {
            questionId = Guid.NewGuid(),
            version = 1,
            title = "t",
            type = QuestionTypes.SingleChoice,
            options = Array.Empty<object>(),
            project = new { projectId = "proj-123" },
        };

        var response = await Client.PostAsync("/api/templates", Wrap(question));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("options_required", body?.Error);
    }

    [Fact]
    public async Task DuplicateTemplate_Returns409TemplateExists()
    {
        var template = ValidSingleChoice();

        var first = await Client.PostAsync("/api/templates", Wrap(template));
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);

        var second = await Client.PostAsync("/api/templates", Wrap(template));
        var body = await second.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.Conflict, second.StatusCode);
        Assert.Equal("template_exists", body?.Error);
    }

    [Fact]
    public async Task MultiFieldInvalidPayload_Returns400WithAllViolations()
    {
        // Passes the envelope/type/options gates (valid singleChoice with 2 options) so the
        // template validator runs and collects MULTIPLE violations at once: empty questionId
        // and empty projectId. Exact count is not asserted so new rules don't break this.
        var question = new
        {
            questionId = Guid.Empty,
            version = 1,
            title = "t",
            type = QuestionTypes.SingleChoice,
            options = new[]
            {
                new { optionId = Guid.NewGuid(), key = "a", title = "A" },
                new { optionId = Guid.NewGuid(), key = "b", title = "B" },
            },
            project = new { projectId = "" },
        };

        var response = await Client.PostAsync("/api/templates", Wrap(question));
        var body = await response.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.NotNull(body?.Errors);
        Assert.Contains(body.Errors, e => e.Contains("questionId"));
        Assert.Contains(body.Errors, e => e.Contains("project.projectId"));
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
        var question = new
        {
            questionId = Guid.NewGuid(),
            version = 1,
            title = "t",
            type = QuestionTypes.SingleChoice,
            options = new[]
            {
                new { optionId = Guid.NewGuid(), key = "a", title = "A" },
                new { optionId = Guid.NewGuid(), key = "b", title = "B" },
            },
            project = (object?)null,
        };

        var response = await Client.PostAsync("/api/templates", Wrap(question));
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

        var response = await Client.PostAsync("/api/templates", Wrap(template));
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

        var response = await Client.PostAsync("/api/templates", Wrap(template));
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

        var response = await Client.PostAsync("/api/templates", Wrap(template));
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

        var response = await Client.PostAsync("/api/templates", Wrap(template));
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
