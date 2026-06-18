using Dotbot.Server.Models;
using Dotbot.Server.Models.Envelope;
using Dotbot.Server.Services;
using Dotbot.Server.Tests.Integration.TestDoubles;

namespace Dotbot.Server.Tests.Unit;

public class EnvelopeAssemblerTests
{
    private const string ProjectId = "proj-assemble";

    private static (EnvelopeAssembler assembler, QuestionInstance instance, Guid questionId) Setup(string type = QuestionTypes.Approval)
    {
        var questionId = Guid.NewGuid();
        var templates = new InMemoryTemplateStorage();
        templates.SaveTemplateAsync(new QuestionTemplate
        {
            QuestionId = questionId,
            Version = 1,
            Title = "Approve?",
            Type = type,
            Options = [],
            Project = new ProjectRef { ProjectId = ProjectId, Name = "Proj" },
        }).GetAwaiter().GetResult();

        var instance = new QuestionInstance
        {
            InstanceId = Guid.NewGuid(),
            QuestionId = questionId,
            QuestionVersion = 1,
            ProjectId = ProjectId,
            OutpostInstanceId = Guid.NewGuid(),
            TaskId = "task-1",
            MothershipUrl = "https://m.example.com",
            SentAt = new DateTime(2026, 5, 21, 9, 30, 0, DateTimeKind.Utc),
            SentTo = [new InstanceRecipient { Email = "a@example.com", Channel = "teams" }],
        };

        return (new EnvelopeAssembler(templates), instance, questionId);
    }

    private static ResponseRecordV2 Approval(QuestionInstance instance, string decision, DateTime at, string via) => new()
    {
        ResponseId = Guid.NewGuid(),
        InstanceId = instance.InstanceId,
        QuestionId = instance.QuestionId,
        ProjectId = ProjectId,
        SubmittedAt = at,
        AnsweredVia = via,
        ApprovalDecision = decision,
        ResponderEmail = "r@example.com",
    };

    [Fact]
    public async Task AssembleInstanceRecord_HasEnvelopeQuestionAndRecipients()
    {
        var (assembler, instance, questionId) = Setup();

        var record = await assembler.AssembleInstanceRecordAsync(instance);

        Assert.Equal(instance.InstanceId, record.Envelope.QuestionInstanceId);
        Assert.Equal(instance.OutpostInstanceId, record.Envelope.OutpostInstanceId);
        Assert.Equal("task-1", record.Envelope.TaskId);
        Assert.Equal("2026-05-21T09:30:00Z", record.Envelope.SentAt);
        Assert.NotNull(record.Question);
        Assert.Equal(questionId.ToString(), record.Question!.Value.GetProperty("questionId").GetString());
        Assert.NotNull(record.Recipients);
        Assert.Single(record.Recipients!);
        Assert.Null(record.Answer);
    }

    [Fact]
    public async Task AssembleResponses_OrdersBySubmittedAt_AndComputesAgreesWithFirst_Disagreement()
    {
        var (assembler, instance, _) = Setup();
        // Provide out of order; assembler must sort ascending by submittedAt.
        var later = Approval(instance, "rejected", new DateTime(2026, 5, 21, 9, 54, 2, DateTimeKind.Utc), "mothership");
        var earlier = Approval(instance, "approved", new DateTime(2026, 5, 21, 9, 38, 11, DateTimeKind.Utc), "outpost");

        var list = await assembler.AssembleResponsesAsync(instance, new[] { later, earlier });

        Assert.Equal(2, list.Count);
        // Earliest first, no agreesWithFirst on it.
        Assert.Equal("approved", list[0].Answer!.ApprovalDecision);
        Assert.Equal("outpost", list[0].Envelope.AnsweredVia);
        Assert.Null(list[0].Envelope.AgreesWithFirst);
        // Later record disagrees with the first.
        Assert.Equal("rejected", list[1].Answer!.ApprovalDecision);
        Assert.False(list[1].Envelope.AgreesWithFirst);
        Assert.Equal("2026-05-21T09:54:02Z", list[1].Envelope.SubmittedAt);
    }

    [Fact]
    public async Task AssembleResponses_AgreesWithFirst_True_WhenSameDecision()
    {
        var (assembler, instance, _) = Setup();
        var first = Approval(instance, "approved", new DateTime(2026, 5, 21, 9, 38, 11, DateTimeKind.Utc), "outpost");
        var second = Approval(instance, "approved", new DateTime(2026, 5, 21, 9, 40, 0, DateTimeKind.Utc), "mothership");

        var list = await assembler.AssembleResponsesAsync(instance, new[] { first, second });

        Assert.Null(list[0].Envelope.AgreesWithFirst);
        Assert.True(list[1].Envelope.AgreesWithFirst);
    }

    [Fact]
    public async Task AssembleResponses_NonApproval_AgreesWithFirstIsNull()
    {
        var (assembler, instance, _) = Setup(QuestionTypes.FreeText);
        var first = new ResponseRecordV2
        {
            ResponseId = Guid.NewGuid(), InstanceId = instance.InstanceId, QuestionId = instance.QuestionId,
            ProjectId = ProjectId, SubmittedAt = new DateTime(2026, 5, 21, 9, 0, 0, DateTimeKind.Utc),
            AnsweredVia = "mothership", FreeText = "first",
        };
        var second = new ResponseRecordV2
        {
            ResponseId = Guid.NewGuid(), InstanceId = instance.InstanceId, QuestionId = instance.QuestionId,
            ProjectId = ProjectId, SubmittedAt = new DateTime(2026, 5, 21, 9, 5, 0, DateTimeKind.Utc),
            AnsweredVia = "mothership", FreeText = "second",
        };

        var list = await assembler.AssembleResponsesAsync(instance, new[] { first, second });

        Assert.Null(list[0].Envelope.AgreesWithFirst);
        Assert.Null(list[1].Envelope.AgreesWithFirst); // no approvalDecision to compare
    }
}
