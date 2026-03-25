namespace Dotbot.Server.Models;

public class DeliveryChannelSettings
{
    public EmailChannelSettings Email { get; set; } = new();
    public JiraChannelSettings Jira { get; set; } = new();
    public SlackChannelSettings Slack { get; set; } = new();
}

public class EmailChannelSettings
{
    public bool Enabled { get; set; }
    public string? SenderAddress { get; set; }
    public string SenderDisplayName { get; set; } = "Dotbot";
}

public class JiraChannelSettings
{
    public bool Enabled { get; set; }
    public string? BaseUrl { get; set; }
    public string? Username { get; set; }
    public string? ApiToken { get; set; }
}

public class SlackChannelSettings
{
    public bool Enabled { get; set; }
    public string? BotToken { get; set; }
}
