namespace Dotbot.Server.Models;

public class BusinessHoursSettings
{
    public bool Enabled { get; set; }
    public int StartHour { get; set; } = 8;
    public int EndHour { get; set; } = 18;
    public List<string> ExemptChannels { get; set; } = new();
    public string FallbackTimeZone { get; set; } = "UTC";
    public string FallbackCountryCode { get; set; } = "GB";
}
