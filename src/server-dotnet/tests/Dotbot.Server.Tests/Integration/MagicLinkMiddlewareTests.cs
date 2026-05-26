using Dotbot.Server.Models;
using System.Net;
using System.Net.Http.Json;

namespace Dotbot.Server.Tests.Integration;

/// <summary>
/// End-to-end coverage of <see cref="Dotbot.Server.MagicLinkAuthMiddleware"/>.
/// Exercises the four user-visible status codes the middleware emits, plus the
/// happy path through to the attachment endpoint, against in-memory storage
/// doubles registered by <see cref="DotbotApiFactory"/>.
/// </summary>
public sealed class MagicLinkMiddlewareTests(DotbotApiFactory factory)
    : IntegrationTestBase(factory)
{
    private const string ProjectId = "p-mw";

    // Both protected surfaces - shared by Theory data so endpoint-symmetric
    // rejection rules are checked against each one.
    private const string AttachmentPathStub = "/api/attachments/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/file.pdf";
    private const string RespondPathStub = "/respond";

    /// <summary>
    /// Builds a published template (in InMemoryTemplateStorage) carrying one attachment,
    /// an instance pointing at it (in InMemoryInstanceStorage), and seeds the attachment
    /// bytes (in InMemoryAttachmentStorage). Returns the storageRef so callers can hit
    /// <c>GET /api/attachments/{storageRef}</c> against the instance.
    /// </summary>
    private async Task<(Guid InstanceId, string StorageRef)> SeedAttachmentScenarioAsync(
        byte[]? content = null, string suffix = "primary")
    {
        var questionId = Guid.NewGuid();
        var attachmentId = Guid.NewGuid();
        var storageRef = $"{attachmentId}/{suffix}.pdf";
        var bytes = content ?? System.Text.Encoding.UTF8.GetBytes($"contents-of-{suffix}");

        Factory.AttachmentStorage.Seed(storageRef, bytes, "application/pdf", name: $"{suffix}.pdf");

        var template = new QuestionTemplate
        {
            QuestionId = questionId,
            Version = 1,
            Title = $"Review {suffix}",
            Type = QuestionTypes.DocumentReview,
            DeliverableSummary = "review",
            Options = new(),
            Project = new ProjectRef { ProjectId = ProjectId, Name = "MW" },
            Attachments = new List<QuestionAttachment>
            {
                new() { AttachmentId = attachmentId, Name = $"{suffix}.pdf", BlobPath = storageRef, MediaType = "application/pdf" },
            },
        };
        await Factory.TemplateStorage.SaveTemplateAsync(template);

        var instanceId = Guid.NewGuid();
        await Factory.InstanceStorage.SaveInstanceAsync(new QuestionInstance
        {
            InstanceId = instanceId,
            QuestionId = questionId,
            QuestionVersion = 1,
            ProjectId = ProjectId,
        });

        return (instanceId, storageRef);
    }

    private async Task<string> MintTokenAsync(Guid instanceId, string email = "reviewer@example.com")
    {
        var resp = await Client.PostAsJsonAsync("/api/test/magic-link", new
        {
            projectId = ProjectId,
            instanceId,
            recipientEmail = email,
        });
        resp.EnsureSuccessStatusCode();
        var body = await resp.Content.ReadFromJsonAsync<MintMagicLinkResponse>();
        return body!.Token;
    }

    // ── Symmetric rejection rules: same outcome on /api/attachments + /respond ──
    //
    // The middleware short-circuits before any storage lookup for these three
    // cases, so the URL only needs to be on a protected path. Theories collapse
    // the (attachment-path, respond-path) duplication.

    [Theory]
    [InlineData(AttachmentPathStub)]
    [InlineData(RespondPathStub)]
    public async Task Middleware_NoToken_Returns401(string path)
    {
        var resp = await Client.GetAsync(path);

        Assert.Equal(HttpStatusCode.Unauthorized, resp.StatusCode);
    }

    [Theory]
    [InlineData(AttachmentPathStub + "?token=garbage.garbage.garbage")]
    [InlineData(RespondPathStub + "?token=garbage.garbage.garbage")]
    public async Task Middleware_UnparseableToken_Returns401(string path)
    {
        // Pre-fix this returned 500: ArgumentException from JwtSecurityTokenHandler
        // wasn't caught alongside SecurityTokenException.
        var resp = await Client.GetAsync(path);

        Assert.Equal(HttpStatusCode.Unauthorized, resp.StatusCode);
    }

    [Theory]
    [InlineData("/api/attachments/{ref}?token={token}")]
    [InlineData("/respond?token={token}")]
    public async Task Middleware_ExpiredJtiBlob_Returns410Gone(string urlTemplate)
    {
        // JWT exp is in the future (30-day default) but the persisted JTI blob's
        // ExpiresAt is in the past. The middleware's belt-and-braces second check
        // must trip and emit 410 Gone for BOTH protected surfaces, not 401.
        var (instanceId, storageRef) = await SeedAttachmentScenarioAsync();
        var token = await MintTokenAsync(instanceId);
        var jti = Factory.TokenStorage.Jtis.Keys.Single();
        Factory.TokenStorage.Jtis[jti].ExpiresAt = DateTime.UtcNow.AddDays(-1);

        var url = urlTemplate.Replace("{ref}", storageRef).Replace("{token}", token);
        var resp = await Client.GetAsync(url);

        Assert.Equal(HttpStatusCode.Gone, resp.StatusCode);
        var body = await resp.Content.ReadAsStringAsync();
        Assert.Contains("expired", body, StringComparison.OrdinalIgnoreCase);
    }

    // ── Attachment-specific cases (ownership + tampered sig + consumed JTI + happy) ──
    //
    // These only apply to /api/attachments. /respond's analogous "wrong instance"
    // doesn't exist (any valid JWT for any instance is allowed to view its own
    // /respond page), so they aren't symmetric.

    [Fact]
    public async Task GetAttachment_TamperedSignature_Returns401()
    {
        var (instanceId, storageRef) = await SeedAttachmentScenarioAsync();
        var token = await MintTokenAsync(instanceId);
        var tampered = token[..^5] + "XXXXX";

        var resp = await Client.GetAsync($"/api/attachments/{storageRef}?token={tampered}");

        Assert.Equal(HttpStatusCode.Unauthorized, resp.StatusCode);
    }

    [Fact]
    public async Task GetAttachment_WrongInstanceJwt_Returns403()
    {
        // Two independent (instance, template, attachment) trios. Token for instance B
        // hits instance A's storageRef - the middleware ownership check rejects it
        // because the storageRef isn't referenced by instance B's template.
        var (_, storageRefA) = await SeedAttachmentScenarioAsync(suffix: "a");
        var (instanceB, _) = await SeedAttachmentScenarioAsync(suffix: "b");
        var tokenB = await MintTokenAsync(instanceB);

        var resp = await Client.GetAsync($"/api/attachments/{storageRefA}?token={tokenB}");

        Assert.Equal(HttpStatusCode.Forbidden, resp.StatusCode);
        var body = await resp.Content.ReadAsStringAsync();
        Assert.Contains("does not grant access", body);
    }

    [Fact]
    public async Task GetAttachment_ConsumedJti_Returns401()
    {
        // Belt-and-braces: a consumed JTI must not be reusable for attachment downloads
        // even before the JWT exp claim expires.
        var (instanceId, storageRef) = await SeedAttachmentScenarioAsync();
        var token = await MintTokenAsync(instanceId);
        var jti = Factory.TokenStorage.Jtis.Keys.Single();
        await Factory.TokenStorage.TryMarkMagicLinkUsedAsync(jti, "device-1");

        var resp = await Client.GetAsync($"/api/attachments/{storageRef}?token={token}");

        Assert.Equal(HttpStatusCode.Unauthorized, resp.StatusCode);
    }

    [Fact]
    public async Task GetAttachment_ValidToken_Returns200WithBytes()
    {
        var content = System.Text.Encoding.UTF8.GetBytes("happy-path-bytes");
        var (instanceId, storageRef) = await SeedAttachmentScenarioAsync(content: content);
        var token = await MintTokenAsync(instanceId);

        var resp = await Client.GetAsync($"/api/attachments/{storageRef}?token={token}");

        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        Assert.Equal("application/pdf", resp.Content.Headers.ContentType?.MediaType);
        var streamed = await resp.Content.ReadAsByteArrayAsync();
        Assert.Equal(content, streamed);
    }

    // ── /respond-only HEAD semantics ───────────────────────────────────────

    [Fact]
    public async Task HeadRespond_NeverConsumesToken_Returns200()
    {
        // Teams (and other clients) issue HEAD previews. Must not consume the JTI.
        var (instanceId, _) = await SeedAttachmentScenarioAsync();
        var token = await MintTokenAsync(instanceId);
        var jti = Factory.TokenStorage.Jtis.Keys.Single();

        var resp = await Client.SendAsync(new HttpRequestMessage(HttpMethod.Head, $"/respond?token={token}"));

        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        Assert.False(Factory.TokenStorage.Jtis[jti].Used);
    }

    private sealed record MintMagicLinkResponse(string Token, string RedemptionUrl);
}
