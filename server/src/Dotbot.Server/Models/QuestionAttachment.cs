namespace Dotbot.Server.Models;

public class QuestionAttachment
{
    public required Guid AttachmentId { get; set; }
    public required string Name { get; set; }
    public string? MediaType { get; set; }
    public string? Url { get; set; }
    public string? BlobPath { get; set; }
    public long? SizeBytes { get; set; }
}
