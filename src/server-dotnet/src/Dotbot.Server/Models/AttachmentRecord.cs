namespace Dotbot.Server.Models;

public class AttachmentRecord
{
    public required string Name { get; set; }
    public required long SizeBytes { get; set; }
    public required string BlobPath { get; set; }
}
