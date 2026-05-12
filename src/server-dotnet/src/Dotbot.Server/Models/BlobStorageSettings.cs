namespace Dotbot.Server.Models;

public class BlobStorageSettings
{
    public string Backend { get; set; } = "AzureBlob";
    public int MaxAttachmentSizeMb { get; set; } = 15;
    public string LocalStoragePath { get; set; } = "attachments";
}
