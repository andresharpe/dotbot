namespace Dotbot.Server.Models;

public static class ApprovalDecisions
{
    public const string Approved = "approved";
    public const string Rejected = "rejected";

    public static readonly string[] ApprovalAllowed = [Approved, Rejected];

    public static string Label(string decision) => decision switch
    {
        Approved => "Approve",
        Rejected => "Reject",
        _ => decision,
    };
}
