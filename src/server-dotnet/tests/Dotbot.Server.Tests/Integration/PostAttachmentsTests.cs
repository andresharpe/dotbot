using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Tests.Integration;

public class PostAttachmentsTests : IntegrationTestBase
{
    public PostAttachmentsTests(DotbotApiFactory factory) : base(factory) { }

    private static MultipartFormDataContent FormWithFile(string fileName, string content = "data")
    {
        var bytes = Encoding.UTF8.GetBytes(content);
        var fileContent = new ByteArrayContent(bytes);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return new MultipartFormDataContent
        {
            { fileContent, "file", fileName }
        };
    }

    [Theory]
    [InlineData("payload.exe")]
    [InlineData("installer.msi")]
    [InlineData("library.dll")]
    [InlineData("run.bat")]
    [InlineData("install.sh")]
    [InlineData("script.ps1")]
    [InlineData("cmd.cmd")]
    [InlineData("screen.scr")]
    [InlineData("macro.vbs")]
    public async Task BlacklistedExtension_ReturnsBadRequest(string fileName)
    {
        using var form = FormWithFile(fileName);

        var response = await Client.PostAsync("/api/attachments", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

        var body = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(body);
        var error = doc.RootElement.GetProperty("error").GetString();
        Assert.NotNull(error);
        Assert.Contains("not allowed", error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task BlacklistedExtension_IsCaseInsensitive()
    {
        using var form = FormWithFile("Malware.EXE");

        var response = await Client.PostAsync("/api/attachments", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task MissingFileField_ReturnsBadRequest()
    {
        using var form = new MultipartFormDataContent
        {
            { new StringContent("not a file"), "other" }
        };

        var response = await Client.PostAsync("/api/attachments", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Theory]
    [InlineData("design.pdf", "application/pdf")]
    [InlineData("notes.txt", "text/plain")]
    [InlineData("diagram.png", "image/png")]
    public async Task AllowedExtension_UploadsAndReturnsMetadata(string fileName, string contentType)
    {
        const string body = "test file content";
        var bytes = Encoding.UTF8.GetBytes(body);
        var fileContent = new ByteArrayContent(bytes);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue(contentType);

        using var form = new MultipartFormDataContent
        {
            { fileContent, "file", fileName }
        };

        var response = await Client.PostAsync("/api/attachments", form);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var responseBody = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(responseBody);
        var root = doc.RootElement;

        Assert.True(root.TryGetProperty("attachmentId", out var idProp));
        Assert.True(Guid.TryParse(idProp.GetString(), out var attachmentId) && attachmentId != Guid.Empty);

        Assert.True(root.TryGetProperty("storageRef", out var refProp));
        Assert.False(string.IsNullOrWhiteSpace(refProp.GetString()));

        Assert.Equal(fileName, root.GetProperty("name").GetString());
        Assert.Equal(contentType, root.GetProperty("contentType").GetString());
        Assert.Equal(bytes.Length, root.GetProperty("sizeBytes").GetInt64());
    }
}
