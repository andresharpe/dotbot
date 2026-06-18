using System.Collections.Concurrent;
using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using PublicHoliday;

namespace Dotbot.Server.Services;

/// <summary>
/// Central gate for business hours awareness. Checks whether it is OK to
/// deliver a message to a specific user right now, considering their local
/// timezone, weekends, and public holidays.
/// </summary>
public class BusinessHoursService
{
    private readonly UserResolverService _userResolver;
    private readonly BusinessHoursSettings _settings;
    private readonly ILogger<BusinessHoursService> _logger;

    // In-memory cache: userId → (locale, fetchedAtUtc)
    private readonly ConcurrentDictionary<string, (TimeZoneInfo Tz, string? Country, DateTime FetchedAt)> _cache = new();
    private static readonly TimeSpan CacheTtl = TimeSpan.FromHours(24);

    public BusinessHoursService(
        UserResolverService userResolver,
        IOptions<BusinessHoursSettings> settings,
        ILogger<BusinessHoursService> logger)
    {
        _userResolver = userResolver;
        _settings = settings.Value;
        _logger = logger;
    }

    /// <summary>
    /// Returns true if delivery is allowed to this user right now.
    /// If the feature is disabled, always returns true.
    /// </summary>
    public async Task<bool> IsWithinBusinessHoursAsync(string? userIdOrEmail, string channel)
    {
        if (!_settings.Enabled)
            return true;

        // Exempt channels bypass all checks
        if (_settings.ExemptChannels.Any(c => string.Equals(c, channel, StringComparison.OrdinalIgnoreCase)))
            return true;

        if (string.IsNullOrEmpty(userIdOrEmail))
            return true; // No user to check — allow delivery

        var (tz, country) = await GetUserLocaleAsync(userIdOrEmail);
        var localNow = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, tz);

        // Weekend check (Sat/Sun)
        if (localNow.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
        {
            _logger.LogDebug("Outside business hours for {User}: weekend ({Day})",
                userIdOrEmail, localNow.DayOfWeek);
            return false;
        }

        // Public holiday check
        if (!string.IsNullOrEmpty(country) && IsPublicHoliday(localNow, country))
        {
            _logger.LogDebug("Outside business hours for {User}: public holiday in {Country}",
                userIdOrEmail, country);
            return false;
        }

        // Hour-of-day check
        if (localNow.Hour < _settings.StartHour || localNow.Hour >= _settings.EndHour)
        {
            _logger.LogDebug("Outside business hours for {User}: local time {LocalTime} not in {Start}-{End}",
                userIdOrEmail, localNow.ToString("HH:mm"), _settings.StartHour, _settings.EndHour);
            return false;
        }

        return true;
    }

    private async Task<(TimeZoneInfo Tz, string? Country)> GetUserLocaleAsync(string userIdOrEmail)
    {
        // Check cache first
        if (_cache.TryGetValue(userIdOrEmail, out var cached) &&
            DateTime.UtcNow - cached.FetchedAt < CacheTtl)
        {
            return (cached.Tz, cached.Country);
        }

        var fallbackTz = ParseTimeZone(_settings.FallbackTimeZone) ?? TimeZoneInfo.Utc;
        var (tz, country) = await _userResolver.ResolveUserLocaleAsync(userIdOrEmail, fallbackTz);

        if (string.IsNullOrEmpty(country))
            country = _settings.FallbackCountryCode;

        _cache[userIdOrEmail] = (tz, country, DateTime.UtcNow);
        return (tz, country);
    }

    private static TimeZoneInfo? ParseTimeZone(string? id)
    {
        if (string.IsNullOrEmpty(id))
            return null;
        try
        {
            return TimeZoneInfo.FindSystemTimeZoneById(id);
        }
        catch (TimeZoneNotFoundException)
        {
            return null;
        }
    }

    private static bool IsPublicHoliday(DateTime localDate, string countryCode)
    {
        var provider = GetHolidayProvider(countryCode);
        if (provider is null)
            return false;

        try
        {
            return provider.IsPublicHoliday(localDate.Date);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Maps ISO 3166-1 alpha-2 country codes to PublicHoliday providers.
    /// Returns null for unsupported countries (holiday check is skipped).
    /// </summary>
    private static IPublicHolidays? GetHolidayProvider(string countryCode) =>
        countryCode.ToUpperInvariant() switch
        {
            "AT" => new AustriaPublicHoliday(),
            "AU" => new AustraliaPublicHoliday(),
            "BE" => new BelgiumPublicHoliday(),
            "BR" => new BrazilPublicHoliday(),
            "CA" => new CanadaPublicHoliday(),
            "CH" => new SwitzerlandPublicHoliday { Canton = SwitzerlandPublicHoliday.Cantons.ALL },
            "CZ" => new CzechRepublicPublicHoliday(),
            "DE" => new GermanPublicHoliday(),
            "DK" => new DenmarkPublicHoliday(),
            "EE" => new EstoniaPublicHoliday(),
            "ES" => new SpainPublicHoliday(),
            "FI" => new FinlandPublicHoliday(),
            "FR" => new FrancePublicHoliday(),
            "GB" => new UKBankHoliday(),
            "GR" => new GreecePublicHoliday(),
            "HR" => new CroatiaPublicHoliday(),
            "IE" => new IrelandPublicHoliday(),
            "IT" => new ItalyPublicHoliday(),
            "JP" => new JapanPublicHoliday(),
            "KZ" => new KazakhstanPublicHoliday(),
            "LT" => new LithuaniaPublicHoliday(),
            "LU" => new LuxembourgPublicHoliday(),
            "MX" => new MexicoPublicHoliday(),
            "NL" => new DutchPublicHoliday(),
            "NO" => new NorwayPublicHoliday(),
            "NZ" => new NewZealandPublicHoliday(),
            "PL" => new PolandPublicHoliday(),
            "PT" => new PortugalPublicHoliday(),
            "SE" => new SwedenPublicHoliday(),
            "SI" => new SloveniaPublicHoliday(),
            "SK" => new SlovakiaPublicHoliday(),
            "TR" => new TurkeyPublicHoliday(),
            "US" => new USAPublicHoliday(),
            _ => null
        };
}
