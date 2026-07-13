using System.Text.Json.Serialization;

namespace Dotbot.Server.Models;

// UI-facing wire shape for a fleet health alert (#547). Active vs history is a filter
// on Status, not two separate stores. Served from mock fixtures now; #598 swaps the
// backing IFleetService to the live AlertService feed (#95).
public sealed class FleetAlertDto
{
    public string Id { get; set; } = "";

    // critical | warning | info
    public string Severity { get; set; } = "";

    public string InstanceId { get; set; } = "";
    public string Message { get; set; } = "";
    public DateTime CreatedAt { get; set; }

    // active | cleared
    public string Status { get; set; } = "";

    // Set when the alert has been cleared/resolved.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DateTime? ResolvedAt { get; set; }
}
