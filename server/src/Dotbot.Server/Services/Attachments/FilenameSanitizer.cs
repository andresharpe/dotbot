namespace Dotbot.Server.Services.Attachments;

/// <summary>
/// Produces a URL- and blob-storage-safe last-path-segment from a raw
/// user-supplied filename. Original filenames are still kept on the
/// <c>AttachmentRecord.Name</c> field for display and Content-Disposition
/// fallback — this helper exists so paths embedded in URLs can't contain
/// characters that break URI parsing (<c>?</c>, <c>#</c>, <c>%</c>, space,
/// non-ASCII, control bytes, RTL overrides, etc.).
/// </summary>
public static class FilenameSanitizer
{
    private const int MaxLength = 200;
    private const string Fallback = "file";

    /// <summary>
    /// Strips directory separators (defence-in-depth on top of
    /// <c>Path.GetFileName</c>, with backslashes normalized first so the
    /// behaviour is identical on Windows and Linux/macOS) and replaces any
    /// character that is not ASCII letter, digit, dot, dash, or underscore
    /// with a single '_'. Runs of '_' collapse to one. Trims leading and
    /// trailing '_' only — dots are preserved so the extension survives
    /// when the stem collapses entirely (e.g. "<paramref name="raw"/>" =
    /// all-non-ASCII becomes ".pdf"). Caps length at 200. Falls back to
    /// "file" when the result is empty, "." or "..".
    /// </summary>
    public static string ToBlobSafe(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return Fallback;

        // `Path.GetFileName` only treats the OS-native directory separator as a separator —
        // on Linux/macOS `\` is a legal filename character, so `"..\\..\\boot.ini"` survives
        // intact and bypasses the traversal strip. Normalize all backslashes to forward
        // slashes first so the behaviour is identical across platforms.
        var name = Path.GetFileName(raw.Replace('\\', '/'));
        if (string.IsNullOrWhiteSpace(name)) return Fallback;

        var sb = new System.Text.StringBuilder(name.Length);
        var prevUnderscore = false;
        foreach (var c in name)
        {
            var safe = char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_';
            if (safe)
            {
                sb.Append(c);
                prevUnderscore = c == '_';
            }
            else if (!prevUnderscore)
            {
                sb.Append('_');
                prevUnderscore = true;
            }
        }

        // Trim only underscores so the extension (e.g. ".pdf") is preserved when the stem
        // collapses entirely (all-non-ASCII filenames). Leading dots are kept — `Path.GetFileName`
        // upstream already stripped directory traversal, and a single literal "." or ".." segment
        // is rejected by AttachmentStorageHelpers.IsStorageRefSafe on the read path.
        var result = sb.ToString().Trim('_');
        if (result.Length == 0 || result == "." || result == "..") return Fallback;
        if (result.Length > MaxLength) result = result[..MaxLength];
        return result;
    }
}
