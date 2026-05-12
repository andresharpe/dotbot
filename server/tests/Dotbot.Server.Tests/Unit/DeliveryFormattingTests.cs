using System.Globalization;
using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Tests.Unit;

public class DeliveryFormattingTests
{
    [Theory]
    [InlineData(null, "—")]
    [InlineData(0L, "0 B")]
    [InlineData(512L, "512 B")]
    [InlineData(1023L, "1023 B")]
    [InlineData(1024L, "1 KB")]
    [InlineData(1536L, "1.5 KB")]
    [InlineData(2048L, "2 KB")]
    [InlineData(1048575L, "1024 KB")]
    [InlineData(1048576L, "1 MB")]
    [InlineData(1572864L, "1.5 MB")]
    [InlineData(5242880L, "5 MB")]
    public void FormatBytes_ProducesExpected(long? bytes, string expected)
    {
        Assert.Equal(expected, DeliveryFormatting.FormatBytes(bytes));
    }

    [Fact]
    public void FormatUtc_FormatsAsExpectedInEnUs()
    {
        var dt = new DateTime(2026, 5, 1, 17, 0, 0, DateTimeKind.Utc);
        Assert.Equal("2026-05-01 17:00 UTC", DeliveryFormatting.FormatUtc(dt));
    }

    [Fact]
    public void FormatUtc_ConvertsLocalToUtc()
    {
        var local = new DateTime(2026, 5, 1, 17, 0, 0, DateTimeKind.Local);
        var expected = local.ToUniversalTime().ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) + " UTC";
        Assert.Equal(expected, DeliveryFormatting.FormatUtc(local));
    }

    [Theory]
    [InlineData("fi-FI")]   // separator '.', not '-'/':'
    [InlineData("de-DE")]   // separator '.'
    [InlineData("ar-SA")]   // RTL + Hijri default calendar
    public void FormatUtc_IsCultureInvariant(string cultureName)
    {
        var prevCulture = CultureInfo.CurrentCulture;
        var prevUiCulture = CultureInfo.CurrentUICulture;
        try
        {
            var c = new CultureInfo(cultureName);
            CultureInfo.CurrentCulture = c;
            CultureInfo.CurrentUICulture = c;

            var dt = new DateTime(2026, 5, 1, 17, 0, 0, DateTimeKind.Utc);
            Assert.Equal("2026-05-01 17:00 UTC", DeliveryFormatting.FormatUtc(dt));
        }
        finally
        {
            CultureInfo.CurrentCulture = prevCulture;
            CultureInfo.CurrentUICulture = prevUiCulture;
        }
    }
}
