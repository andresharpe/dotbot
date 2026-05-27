using Dotbot.Server.Services.Attachments;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

/// <summary>
/// In-memory <see cref="IAttachmentStorage"/> for integration tests. Storage refs are
/// the canonical <c>{attachmentGuid}/{fileName}</c> shape so middleware path-matching
/// against <see cref="Dotbot.Server.Models.QuestionAttachment.BlobPath"/> resolves correctly.
/// </summary>
public sealed class InMemoryAttachmentStorage : IAttachmentStorage
{
    private readonly Dictionary<string, (byte[] Content, string ContentType, string Name)> _store = new();

    public IReadOnlyDictionary<string, (byte[] Content, string ContentType, string Name)> Saved => _store;

    public Task ResetAsync()
    {
        _store.Clear();
        return Task.CompletedTask;
    }

    /// <summary>
    /// Test seed helper - pre-populates an attachment with a known storageRef so a
    /// matching <see cref="Dotbot.Server.Models.QuestionAttachment"/> can reference
    /// it without going through the real upload path.
    /// </summary>
    public void Seed(string storageRef, byte[] content, string contentType = "text/plain", string? name = null)
    {
        _store[storageRef] = (content, contentType, name ?? Path.GetFileName(storageRef));
    }

    public Task<AttachmentUploadResult> UploadAsync(
        string fileName, string contentType, Stream content, long sizeBytes, CancellationToken ct = default)
    {
        var attachmentId = Guid.NewGuid();
        var storageRef = $"{attachmentId}/{fileName}";
        using var ms = new MemoryStream();
        content.CopyTo(ms);
        _store[storageRef] = (ms.ToArray(), contentType, fileName);
        return Task.FromResult(new AttachmentUploadResult(attachmentId, storageRef, fileName, contentType, sizeBytes));
    }

    public Task<(Stream Content, string ContentType)?> DownloadAsync(string storageRef, CancellationToken ct = default)
    {
        if (!_store.TryGetValue(storageRef, out var v))
            return Task.FromResult<(Stream, string)?>(null);
        return Task.FromResult<(Stream, string)?>((new MemoryStream(v.Content), v.ContentType));
    }

    public Task DeleteAsync(string storageRef, CancellationToken ct = default)
    {
        _store.Remove(storageRef);
        return Task.CompletedTask;
    }
}
