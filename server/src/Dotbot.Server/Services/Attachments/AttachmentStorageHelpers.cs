namespace Dotbot.Server.Services.Attachments;

internal static class AttachmentStorageHelpers
{
    internal static bool IsStorageRefSafe(string storageRef)
    {
        if (string.IsNullOrEmpty(storageRef)) return false;
        if (Path.IsPathRooted(storageRef)) return false;
        if (storageRef.Contains("..")) return false;
        if (storageRef.Contains('\0')) return false;
        return true;
    }
}
