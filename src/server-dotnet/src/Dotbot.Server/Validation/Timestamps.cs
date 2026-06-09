using System.Globalization;

namespace Dotbot.Server.Validation;

// SPEC-029 sec.5.5: timestamps are UTC ISO 8601 with an explicit Z (or offset).
// Local-time strings (no timezone designator) are rejected.
public static class Timestamps
{
    /// <summary>
    /// Parses an ISO 8601 timestamp that carries an explicit timezone (Z or +/-hh:mm)
    /// and returns it as UTC. Strings with no timezone designator are rejected.
    /// </summary>
    public static bool TryParseUtc(string? value, out DateTime utc)
    {
        utc = default;
        if (string.IsNullOrWhiteSpace(value))
            return false;

        if (!DateTime.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out var parsed))
            return false;

        // RoundtripKind yields Unspecified for a string with no Z/offset - reject those.
        if (parsed.Kind == DateTimeKind.Unspecified)
            return false;

        utc = parsed.ToUniversalTime();
        return true;
    }

    /// <summary>Formats a DateTime as UTC ISO 8601 with the explicit Z suffix.</summary>
    public static string FormatUtc(DateTime value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
}
