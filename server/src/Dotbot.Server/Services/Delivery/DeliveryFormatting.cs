using System.Globalization;

namespace Dotbot.Server.Services.Delivery;

/// <summary>
/// Shared formatting helpers used by every delivery provider's NotificationSummary
/// renderer. Keeps byte-size and timestamp formatting consistent across channels
/// and culture-invariant.
/// </summary>
internal static class DeliveryFormatting
{
    internal static string FormatBytes(long? bytes)
    {
        if (!bytes.HasValue) return "—";
        var b = bytes.Value;
        var inv = CultureInfo.InvariantCulture;
        if (b < 1024) return $"{b} B";
        if (b < 1024L * 1024L) return (b / 1024.0).ToString("0.#", inv) + " KB";
        return (b / (1024.0 * 1024.0)).ToString("0.#", inv) + " MB";
    }

    /// <summary>
    /// Formats a UTC timestamp as <c>yyyy-MM-dd HH:mm UTC</c> using
    /// <see cref="CultureInfo.InvariantCulture"/> so `:` and `-` separators stay
    /// stable across host locales.
    /// </summary>
    internal static string FormatUtc(DateTime dt) =>
        dt.ToUniversalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) + " UTC";
}
