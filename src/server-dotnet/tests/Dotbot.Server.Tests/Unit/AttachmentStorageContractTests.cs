using Dotbot.Server.Models;
using Dotbot.Server.Services.Attachments;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Options;
using System.Text;

namespace Dotbot.Server.Tests.Unit;

public class LocalFileAttachmentStorageContractTests : AttachmentStorageContractTests, IDisposable
{
    private readonly string _tempDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());

    protected override IAttachmentStorage CreateStorage()
    {
        var settings = Options.Create(new BlobStorageSettings { LocalStoragePath = _tempDir });
        var env = new FakeWebHostEnvironment(_tempDir);
        return new LocalFileAttachmentStorage(settings, env);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }
}

public abstract class AttachmentStorageContractTests
{
    protected abstract IAttachmentStorage CreateStorage();

    private static Stream TextStream(string text) =>
        new MemoryStream(Encoding.UTF8.GetBytes(text));

    [Fact]
    public async Task Upload_ThenDownload_MatchesContent()
    {
        var storage = CreateStorage();
        const string body = "hello attachment";
        var result = await storage.UploadAsync("test.txt", "text/plain", TextStream(body), body.Length);

        var downloaded = await storage.DownloadAsync(result.StorageRef);

        Assert.NotNull(downloaded);
        using var reader = new StreamReader(downloaded!.Value.Content);
        Assert.Equal(body, await reader.ReadToEndAsync());
        Assert.Equal("text/plain", downloaded.Value.ContentType);
    }

    [Fact]
    public async Task Download_AfterDelete_ReturnsNull()
    {
        var storage = CreateStorage();
        const string body = "to be deleted";
        var result = await storage.UploadAsync("file.txt", "text/plain", TextStream(body), body.Length);

        await storage.DeleteAsync(result.StorageRef);
        var downloaded = await storage.DownloadAsync(result.StorageRef);

        Assert.Null(downloaded);
    }

    [Fact]
    public async Task Delete_NonExistent_DoesNotThrow()
    {
        var storage = CreateStorage();
        var exception = await Record.ExceptionAsync(() => storage.DeleteAsync("nonexistent/file.txt"));
        Assert.Null(exception);
    }

    [Fact]
    public async Task Download_NonExistent_ReturnsNull()
    {
        var storage = CreateStorage();
        var result = await storage.DownloadAsync("nonexistent/file.txt");
        Assert.Null(result);
    }

    [Theory]
    [InlineData("../escape.txt")]
    [InlineData("../../etc/passwd")]
    [InlineData("/absolute/path.txt")]
    [InlineData("a/../../escape.txt")]
    [InlineData("")]
    [InlineData("a\\b\\escape.txt")]
    [InlineData("a//b")]
    [InlineData("./relative")]
    public async Task Download_PathTraversal_ReturnsNull(string maliciousRef)
    {
        var storage = CreateStorage();
        var result = await storage.DownloadAsync(maliciousRef);
        Assert.Null(result);
    }

    [Fact]
    public async Task Upload_EmptyFileName_Throws()
    {
        var storage = CreateStorage();
        await Assert.ThrowsAsync<ArgumentException>(() =>
            storage.UploadAsync("", "text/plain", new MemoryStream([1, 2, 3]), 3));
    }

    [Fact]
    public async Task Upload_PreservesContentType()
    {
        var storage = CreateStorage();
        var result = await storage.UploadAsync("diagram.pdf", "application/pdf", TextStream("pdf bytes"), 9);

        var downloaded = await storage.DownloadAsync(result.StorageRef);
        Assert.Equal("application/pdf", downloaded!.Value.ContentType);
    }

    [Fact]
    public async Task Upload_ReturnsCorrectMetadata()
    {
        var storage = CreateStorage();
        const string body = "content";
        var result = await storage.UploadAsync("my file.txt", "text/plain", TextStream(body), body.Length);

        Assert.NotEqual(Guid.Empty, result.AttachmentId);
        Assert.Equal("my file.txt", result.Name);
        Assert.Equal("text/plain", result.ContentType);
        Assert.Equal(body.Length, result.SizeBytes);
        Assert.Contains(result.AttachmentId.ToString(), result.StorageRef);
    }

    [Fact]
    public async Task BothBackendsPassSameContract_UploadThenDownload()
    {
        // Upload two different blobs; each must be independently retrievable
        var storage = CreateStorage();
        var r1 = await storage.UploadAsync("a.txt", "text/plain", TextStream("alpha"), 5);
        var r2 = await storage.UploadAsync("b.txt", "text/plain", TextStream("beta"), 4);

        var d1 = await storage.DownloadAsync(r1.StorageRef);
        var d2 = await storage.DownloadAsync(r2.StorageRef);

        using var reader1 = new StreamReader(d1!.Value.Content);
        using var reader2 = new StreamReader(d2!.Value.Content);
        Assert.Equal("alpha", await reader1.ReadToEndAsync());
        Assert.Equal("beta", await reader2.ReadToEndAsync());
    }
}

// Minimal IWebHostEnvironment stub for tests
file class FakeWebHostEnvironment : IWebHostEnvironment
{
    public FakeWebHostEnvironment(string contentRootPath) => ContentRootPath = contentRootPath;
    public string ContentRootPath { get; set; }
    public string WebRootPath { get; set; } = string.Empty;
    public string EnvironmentName { get; set; } = "Test";
    public string ApplicationName { get; set; } = "Test";
    public Microsoft.Extensions.FileProviders.IFileProvider WebRootFileProvider { get; set; } = null!;
    public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } = null!;
}
