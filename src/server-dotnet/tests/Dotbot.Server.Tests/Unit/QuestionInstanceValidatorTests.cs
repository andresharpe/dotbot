using Dotbot.Server.Models;
using Dotbot.Server.Validation;

namespace Dotbot.Server.Tests.Unit;

public class QuestionInstanceValidatorTests
{
    private static readonly QuestionInstanceValidator Validator = new();

    private static CreateInstanceRequest Request(
        Guid? questionId = null,
        string? channel = "teams",
        string? jiraIssueKey = null,
        Recipients? recipients = null,
        DeliveryOverrides? overrides = null) => new()
    {
        ProjectId = "p1",
        QuestionId = questionId ?? Guid.NewGuid(),
        QuestionVersion = 1,
        Channel = channel!,
        JiraIssueKey = jiraIssueKey,
        Recipients = recipients ?? new Recipients { Emails = new() { "a@b.co" } },
        DeliveryOverrides = overrides,
    };

    [Fact]
    public void Minimal_NoError()
    {
        Assert.Empty(Validator.Validate(Request()));
    }

    // ── QuestionId ─────────────────────────────────────────────────────────

    [Fact]
    public void EmptyQuestionId_Error()
    {
        var errors = Validator.Validate(Request(questionId: Guid.Empty));
        Assert.Single(errors);
        Assert.Contains("questionId", errors[0]);
    }

    // ── JiraIssueKey ───────────────────────────────────────────────────────

    [Fact]
    public void JiraChannel_NoIssueKey_Error()
    {
        var errors = Validator.Validate(Request(channel: "jira"));
        Assert.Single(errors);
        Assert.Contains("jiraIssueKey", errors[0]);
    }

    [Fact]
    public void JiraChannel_WithIssueKey_NoError()
    {
        Assert.Empty(Validator.Validate(Request(channel: "jira", jiraIssueKey: "PROJ-1")));
    }

    [Theory]
    [InlineData("teams")]
    [InlineData("email")]
    [InlineData("slack")]
    public void NonJiraChannel_MissingIssueKey_NoError(string channel)
    {
        Assert.Empty(Validator.Validate(Request(channel: channel)));
    }

    // ── Recipients ─────────────────────────────────────────────────────────

    [Fact]
    public void NoRecipientsAtAll_Error()
    {
        var errors = Validator.Validate(Request(recipients: new Recipients()));
        Assert.Single(errors);
        Assert.Contains("recipients", errors[0]);
    }

    [Theory]
    [InlineData("no-at-sign")]
    [InlineData("@nouser.com")]
    [InlineData("user@")]
    [InlineData("user@nodot")]
    [InlineData("  ")]
    public void InvalidEmail_Error(string email)
    {
        var r = Request(recipients: new Recipients { Emails = new() { email } });
        var errors = Validator.Validate(r);
        Assert.Single(errors);
        Assert.Contains("Invalid email", errors[0]);
    }

    [Fact]
    public void InvalidEmailListed_ReportsAllOffenders()
    {
        var r = Request(recipients: new Recipients
        {
            Emails = new() { "ok@a.co", "bad", "alsobad" },
        });
        var errors = Validator.Validate(r);
        Assert.Single(errors);
        Assert.Contains("bad", errors[0]);
        Assert.Contains("alsobad", errors[0]);
    }

    [Fact]
    public void RecipientsWithOnlyObjectIds_NoError()
    {
        var r = Request(recipients: new Recipients { UserObjectIds = new() { "aad-123" } });
        Assert.Empty(Validator.Validate(r));
    }

    [Fact]
    public void RecipientsWithOnlySlackUserIds_NoError()
    {
        var r = Request(recipients: new Recipients { SlackUserIds = new() { "U123" } });
        Assert.Empty(Validator.Validate(r));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(24)]
    [InlineData(DeliveryDefaults.MaxReminderAfterHours)]
    public void DeliveryOverrides_ReminderAfterHours_InRange_NoError(int value)
    {
        var r = Request(overrides: new DeliveryOverrides { ReminderAfterHours = value });
        Assert.Empty(Validator.Validate(r));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(DeliveryDefaults.MaxReminderAfterHours + 1)]
    [InlineData(int.MaxValue)]
    public void DeliveryOverrides_ReminderAfterHours_OutOfRange_Error(int value)
    {
        var r = Request(overrides: new DeliveryOverrides { ReminderAfterHours = value });
        var errors = Validator.Validate(r);
        Assert.Single(errors);
        Assert.Contains("reminderAfterHours", errors[0]);
        Assert.Contains("deliveryOverrides", errors[0]);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(30)]
    [InlineData(DeliveryDefaults.MaxEscalateAfterDays)]
    public void DeliveryOverrides_EscalateAfterDays_InRange_NoError(int value)
    {
        var r = Request(overrides: new DeliveryOverrides { EscalateAfterDays = value });
        Assert.Empty(Validator.Validate(r));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(DeliveryDefaults.MaxEscalateAfterDays + 1)]
    [InlineData(int.MaxValue)]
    public void DeliveryOverrides_EscalateAfterDays_OutOfRange_Error(int value)
    {
        var r = Request(overrides: new DeliveryOverrides { EscalateAfterDays = value });
        var errors = Validator.Validate(r);
        Assert.Single(errors);
        Assert.Contains("escalateAfterDays", errors[0]);
        Assert.Contains("deliveryOverrides", errors[0]);
    }

    [Fact]
    public void DeliveryOverrides_BothFieldsBad_TwoErrors()
    {
        // Per-field error emission so callers see all reasons at once.
        var r = Request(overrides: new DeliveryOverrides
        {
            ReminderAfterHours = int.MaxValue,
            EscalateAfterDays = int.MaxValue,
        });
        var errors = Validator.Validate(r);
        Assert.Equal(2, errors.Count);
        Assert.Contains(errors, e => e.Contains("reminderAfterHours"));
        Assert.Contains(errors, e => e.Contains("escalateAfterDays"));
    }
}
