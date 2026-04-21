using Dotbot.Server.Models;
using Dotbot.Server.Validation;

namespace Dotbot.Server.Tests.Unit;

public class QuestionTemplateValidatorTests
{
    [Fact]
    public void Validate_MinimalValidSingleChoice_ReturnsNoErrors()
    {
        var errors = QuestionTemplateValidator.Validate(new QuestionTemplate
        {
            QuestionId = Guid.NewGuid(),
            Version = 1,
            Title = "smoke",
            Options = [],
            Project = new ProjectRef { ProjectId = "p1" },
        });

        Assert.Empty(errors);
    }
}
