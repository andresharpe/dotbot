namespace Dotbot.Server.Models;

public class BlobStorageSettings
{
    public string Backend { get; set; } = "AzureBlob";
    public int MaxAttachmentSizeMb { get; set; } = 15;
    public string LocalStoragePath { get; set; } = "attachments";

    // Filename-extension blacklist applied at upload. Empty list → no filtering.
    // PRD-029 §7 polish item: keep this minimal — attachments come from Claude-generated
    // output in practice, so the risk is low; the list exists to block obvious foot-guns.
    public List<string> AllowedExtensionsBlacklist { get; set; } = new()
    {
        ".exe", ".msi", ".dll", ".bat", ".sh", ".ps1", ".cmd", ".scr", ".vbs"
    };
}
