namespace Dotbot.Server.Models;

public class RankedItem
{
    public required Guid OptionId { get; set; }
    public required int Rank { get; set; }
}
