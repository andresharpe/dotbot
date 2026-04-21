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
}
