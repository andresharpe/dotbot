using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace Dotbot.Server.Services.Attachments;

public class LocalFileAttachmentStorage : IAttachmentStorage
{
    private readonly string _basePath;

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = false };

    public LocalFileAttachmentStorage(IOptions<BlobStorageSettings> options, IWebHostEnvironment env)
    {
        var configured = options.Value.LocalStoragePath;
        _basePath = Path.IsPathRooted(configured)
            ? configured
            : Path.GetFullPath(Path.Combine(env.ContentRootPath, configured));

        Directory.CreateDirectory(_basePath);
    }

    public async Task<AttachmentUploadResult> UploadAsync(
        string fileName, string contentType, Stream content, long sizeBytes, CancellationToken ct = default)
    {
        var attachmentId = Guid.NewGuid();
        var safeFileName = Path.GetFileName(fileName);
        var dir = Path.Combine(_basePath, attachmentId.ToString());
        Directory.CreateDirectory(dir);

        var filePath = Path.Combine(dir, safeFileName);
        await using var fs = new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.None);
        await content.CopyToAsync(fs, ct);

        var metaPath = filePath + ".meta";
        var meta = JsonSerializer.Serialize(new { contentType }, JsonOptions);
        await File.WriteAllTextAsync(metaPath, meta, ct);

        return new AttachmentUploadResult(attachmentId, $"{attachmentId}/{safeFileName}", safeFileName, contentType, sizeBytes);
    }

    public async Task<(Stream Content, string ContentType)?> DownloadAsync(string storageRef, CancellationToken ct = default)
    {
        if (!AttachmentStorageHelpers.IsStorageRefSafe(storageRef))
            return null;

        var fullPath = Path.GetFullPath(Path.Combine(_basePath, storageRef));
        if (!fullPath.StartsWith(_basePath, StringComparison.OrdinalIgnoreCase))
            return null;

        if (!File.Exists(fullPath))
            return null;

        var contentType = "application/octet-stream";
        var metaPath = fullPath + ".meta";
        if (File.Exists(metaPath))
        {
            var meta = await File.ReadAllTextAsync(metaPath, ct);
            var doc = JsonDocument.Parse(meta);
            if (doc.RootElement.TryGetProperty("contentType", out var ct2))
                contentType = ct2.GetString() ?? contentType;
        }

        var ms = new MemoryStream();
        await using (var fs = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, useAsync: true))
            await fs.CopyToAsync(ms, ct);
        ms.Position = 0;
        return (ms, contentType);
    }

    public Task DeleteAsync(string storageRef, CancellationToken ct = default)
    {
        if (!AttachmentStorageHelpers.IsStorageRefSafe(storageRef))
            return Task.CompletedTask;

        var fullPath = Path.GetFullPath(Path.Combine(_basePath, storageRef));
        if (!fullPath.StartsWith(_basePath, StringComparison.OrdinalIgnoreCase))
            return Task.CompletedTask;

        if (File.Exists(fullPath))
        {
            File.Delete(fullPath);
            var metaPath = fullPath + ".meta";
            if (File.Exists(metaPath)) File.Delete(metaPath);

            // Remove parent dir if empty
            var dir = Path.GetDirectoryName(fullPath);
            if (dir != null && dir != _basePath && Directory.Exists(dir) && !Directory.EnumerateFileSystemEntries(dir).Any())
                Directory.Delete(dir);
        }

        return Task.CompletedTask;
    }
}
