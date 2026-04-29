using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Dotbot.Server.Models;
using Microsoft.Extensions.Options;

namespace Dotbot.Server.Services.Attachments;

public class AzureBlobAttachmentStorage : IAttachmentStorage
{
    private readonly BlobContainerClient _container;

    public AzureBlobAttachmentStorage(BlobServiceClient blob, IOptions<BlobStorageSettings> options)
    {
        _container = blob.GetBlobContainerClient("template-attachments");
        _container.CreateIfNotExists();
    }

    public async Task<AttachmentUploadResult> UploadAsync(
        string fileName, string contentType, Stream content, long sizeBytes, CancellationToken ct = default)
    {
        var safeFileName = Path.GetFileName(fileName);
        if (string.IsNullOrWhiteSpace(safeFileName))
            throw new ArgumentException("fileName must contain a valid file name.", nameof(fileName));

        var attachmentId = Guid.NewGuid();
        var storageRef = $"{attachmentId}/{safeFileName}";

        var blob = _container.GetBlobClient(storageRef);
        var uploadOptions = new BlobUploadOptions
        {
            HttpHeaders = new BlobHttpHeaders { ContentType = contentType }
        };
        await blob.UploadAsync(content, uploadOptions, ct);

        return new AttachmentUploadResult(attachmentId, storageRef, safeFileName, contentType, sizeBytes);
    }

    public async Task<(Stream Content, string ContentType)?> DownloadAsync(string storageRef, CancellationToken ct = default)
    {
        if (!AttachmentStorageHelpers.IsStorageRefSafe(storageRef))
            return null;

        try
        {
            var blob = _container.GetBlobClient(storageRef);
            var result = await blob.DownloadStreamingAsync(cancellationToken: ct);
            var detectedContentType = result.Value.Details.ContentType ?? "application/octet-stream";
            return (result.Value.Content, detectedContentType);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public async Task DeleteAsync(string storageRef, CancellationToken ct = default)
    {
        if (!AttachmentStorageHelpers.IsStorageRefSafe(storageRef))
            return;

        var blob = _container.GetBlobClient(storageRef);
        await blob.DeleteIfExistsAsync(cancellationToken: ct);
    }
}
