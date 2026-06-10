using Dotbot.Server.Models;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Tests.Integration;

public class PostInstancesTests : IntegrationTestBase
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    public PostInstancesTests(DotbotApiFactory factory) : base(factory) { }

    private const string ProjectId = "proj-inst";
    private static readonly Guid QuestionId = Guid.NewGuid();

    private async Task SeedTemplateAsync() =>
        await Factory.TemplateStorage.SaveTemplateAsync(new QuestionTemplate
        {
            QuestionId = QuestionId,
            Version = 1,
            Title = "Pick",
            Type = QuestionTypes.SingleChoice,
            Options =
            [
                new TemplateOption { OptionId = Guid.NewGuid(), Key = "a", Title = "A" },
                new TemplateOption { OptionId = Guid.NewGuid(), Key = "b", Title = "B" },
            ],
            Project = new ProjectRef { ProjectId = ProjectId },
        });

    private static object Env() => new
    {
        outpostInstanceId = Guid.NewGuid(),
        taskId = "task-inst",
        mothershipUrl = "https://m.example.com",
        questionInstanceId = Guid.Empty,
        projectId = ProjectId,
    };

    private static StringContent Json(object payload) =>
        new(JsonSerializer.Serialize(payload, JsonOpts), Encoding.UTF8, "application/json");

    private sealed class ErrorResponse { public string? Error { get; set; } }

    [Fact]
    public async Task MixedRecipientChannels_Returns400()
    {
        await SeedTemplateAsync();
        var body = new
        {
            envelope = Env(),
            question = new { questionId = QuestionId, version = 1 },
            recipients = new object[]
            {
                new { email = "a@example.com", channel = "teams" },
                new { email = "b@example.com", channel = "email" },
            },
        };

        var resp = await Client.PostAsync("/api/instances", Json(body));
        var err = await resp.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
        Assert.Equal("mixed_recipient_channels", err?.Error);
    }

    [Fact]
    public async Task EmptyRecipient_Returns400InvalidRecipient()
    {
        var body = new
        {
            envelope = Env(),
            question = new { questionId = QuestionId, version = 1 },
            recipients = new object[] { new { channel = "teams" } },
        };

        var resp = await Client.PostAsync("/api/instances", Json(body));
        var err = await resp.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
        Assert.Equal("invalid_recipient", err?.Error);
    }

    [Fact]
    public async Task UnknownTemplate_Returns404TemplateNotFound()
    {
        var body = new
        {
            envelope = Env(),
            question = new { questionId = Guid.NewGuid(), version = 1 },
            recipients = new object[] { new { email = "a@example.com", channel = "teams" } },
        };

        var resp = await Client.PostAsync("/api/instances", Json(body));
        var err = await resp.Content.ReadFromJsonAsync<ErrorResponse>(JsonOpts);

        Assert.Equal(HttpStatusCode.NotFound, resp.StatusCode);
        Assert.Equal("template_not_found", err?.Error);
    }
}
