using System.Text.Json.Serialization;

namespace Dotbot.Server.Models;

// UI-facing wire shape for a registered fleet node (outpost or drone) shown on the
// Fleet dashboard (#547). Scaffolding is served from mock fixtures; #598 swaps the
// backing IFleetService to the live registry, mapping its snake_case fields onto
// this contract, which stays fixed across the swap.
public sealed class FleetInstanceDto
{
    public string InstanceId { get; set; } = "";
    public string Name { get; set; } = "";

    // outpost | drone
    public string Kind { get; set; } = "";

    // online | stale | error
    public string Status { get; set; } = "";

    public string OrgId { get; set; } = "";
    public long UptimeSeconds { get; set; }
    public DateTime LastHeartbeatAt { get; set; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ActiveWorkflow { get; set; }

    public int TaskCount { get; set; }
    public string Version { get; set; } = "";

    // Present for drones, null for outposts.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public DroneUtilizationDto? DroneUtilization { get; set; }
}

public sealed class DroneUtilizationDto
{
    public int Load { get; set; }
    public int MaxConcurrent { get; set; }
    public double SuccessRate { get; set; }
    public int AvgDurationSeconds { get; set; }
}
