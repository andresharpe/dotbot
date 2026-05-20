using Dotbot.Server.Services;

namespace Dotbot.Server.Tests.Unit;

public class MagicLinkExpiryTests
{
    private static readonly DateTime SentAt = new(2026, 5, 1, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void Null_FallsBackTo30Days()
    {
        var exp = MagicLinkService.ComputeExpiry(SentAt, escalateAfterDays: null);
        Assert.Equal(SentAt.AddDays(MagicLinkService.DefaultEscalateAfterDays), exp);
        Assert.Equal(SentAt.AddDays(30), exp);
    }

    [Fact]
    public void Positive_HonouredVerbatim()
    {
        var exp = MagicLinkService.ComputeExpiry(SentAt, escalateAfterDays: 7);
        Assert.Equal(SentAt.AddDays(7), exp);
    }

    [Fact]
    public void Zero_FallsBackTo30Days()
    {
        // Zero is not a valid lifetime — treat the same as null. Catches misconfigured
        // templates from being silently shrunk to "expires immediately".
        var exp = MagicLinkService.ComputeExpiry(SentAt, escalateAfterDays: 0);
        Assert.Equal(SentAt.AddDays(30), exp);
    }

    [Fact]
    public void Negative_FallsBackTo30Days()
    {
        var exp = MagicLinkService.ComputeExpiry(SentAt, escalateAfterDays: -5);
        Assert.Equal(SentAt.AddDays(30), exp);
    }

    [Fact]
    public void DefaultEscalateAfterDays_Is30()
    {
        // Locked by PRD-029 §5.3. Surfaced as a constant so callers (and tests) can
        // assert the contract instead of duplicating the number.
        Assert.Equal(30, MagicLinkService.DefaultEscalateAfterDays);
    }
}
