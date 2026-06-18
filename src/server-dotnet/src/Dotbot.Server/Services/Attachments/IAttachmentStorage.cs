namespace Dotbot.Server.Services.Attachments;

public interface IAttachmentStorage
{
    Task<AttachmentUploadResult> UploadAsync(string fileName, string contentType, Stream content, long sizeBytes, CancellationToken ct = default);
    Task<(Stream Content, string ContentType)?> DownloadAsync(string storageRef, CancellationToken ct = default);
    Task DeleteAsync(string storageRef, CancellationToken ct = default);
}

public record AttachmentUploadResult(Guid AttachmentId, string StorageRef, string Name, string ContentType, long SizeBytes);
