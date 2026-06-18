namespace Dotbot.Server.Services.Attachments;

/// <summary>
/// Produces a URL- and blob-storage-safe last-path-segment from a raw
/// user-supplied filename. The original filename is kept on
/// <c>AttachmentRecord.Name</c> / <c>AttachmentUploadResult.Name</c> for UI
/// display. The download endpoints currently derive the
/// <c>Content-Disposition</c> filename from the sanitized blob path
/// segment, not from the stored display name — wiring the stored name
/// through to the download response is a separate UX improvement.
/// This helper exists so paths embedded in URLs can't contain characters
/// that break URI parsing (<c>?</c>, <c>#</c>, <c>%</c>, space, non-ASCII,
/// control bytes, RTL overrides, etc.).
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
    /// all-non-ASCII becomes ".pdf"). Caps length at 200 while preserving
    /// a short trailing extension (16 chars or fewer including the dot)
    /// so the content-type cue isn't lost on long names. Falls back to
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
        if (result.Length > MaxLength)
        {
            // Preserve a short extension (<=16 chars including the dot) so the truncated
            // filename keeps its content-type cue. Anything longer gets a plain cut.
            var dot = result.LastIndexOf('.');
            var extLen = dot > 0 ? result.Length - dot : 0;
            result = extLen > 0 && extLen <= 16 && extLen < MaxLength
                ? result[..(MaxLength - extLen)] + result[dot..]
                : result[..MaxLength];
        }
        return result;
    }
}
