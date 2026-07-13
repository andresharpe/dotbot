using Dotbot.Server.Models;

namespace Dotbot.Server.Services;

// Data source for the Fleet dashboard (#547). Async so the live HTTP-backed
// implementation (#598) drops in without changing this contract or its callers.
public interface IFleetService
{
    Task<IReadOnlyList<FleetInstanceDto>> GetInstancesAsync();

    // status: "active" | "cleared" | null (all). Active feeds the banner/rail;
    // cleared feeds the alert-history view.
    Task<IReadOnlyList<FleetAlertDto>> GetAlertsAsync(string? status = null);
}
