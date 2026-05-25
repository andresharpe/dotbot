namespace Dotbot.Server.Models;

public static class ApprovalDecisions
{
    public const string Approve = "approve";
    public const string Reject = "reject";
    public const string Abstain = "abstain";

    public const string RequestChanges = "request-changes";
    public const string CommentOnly = "comment-only";

    public static readonly string[] ApprovalAllowed = [Approve, Reject, Abstain];
    public static readonly string[] DocumentReviewAllowed = [Approve, RequestChanges, CommentOnly];

    public static string Label(string decision) => decision switch
    {
        Approve => "Approve",
        Reject => "Reject",
        Abstain => "Abstain",
        RequestChanges => "Request Changes",
        CommentOnly => "Comment Only",
        _ => decision,
    };
}
