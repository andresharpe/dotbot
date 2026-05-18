namespace Dotbot.Server.Models;

public static class QuestionTypes
{
    public const string SingleChoice = "singleChoice";
    public const string MultiChoice = "multiChoice";
    public const string Approval = "approval";
    public const string DocumentReview = "documentReview";
    public const string FreeText = "freeText";
    public const string PriorityRanking = "priorityRanking";

    public static readonly string[] AllowedTypes =
    [
        SingleChoice,
        MultiChoice,
        Approval,
        DocumentReview,
        FreeText,
        PriorityRanking,
    ];

    /// <summary>
    /// True for the question types that render an attachment dropzone in
    /// <c>Pages/Respond.cshtml</c>. Used to ignore files in adversarial POSTs
    /// against types whose UI never offers an upload control.
    /// </summary>
    public static bool SupportsAttachments(string type) =>
        type == SingleChoice || type == MultiChoice;
}
