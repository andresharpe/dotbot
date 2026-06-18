using Dotbot.Server.Services.Attachments;

namespace Dotbot.Server.Tests.Unit;

public class FilenameSanitizerTests
{
    [Theory]
    [InlineData("report.pdf", "report.pdf")]
    [InlineData("my-doc_v2.docx", "my-doc_v2.docx")]
    [InlineData("README.md", "README.md")]
    public void Allowed_characters_pass_through(string input, string expected)
        => Assert.Equal(expected, FilenameSanitizer.ToBlobSafe(input));

    [Theory]
    [InlineData("my report.pdf", "my_report.pdf")]
    [InlineData("what?.pdf", "what_.pdf")]
    [InlineData("anchor#tag.pdf", "anchor_tag.pdf")]
    [InlineData("100%.pdf", "100_.pdf")]
    [InlineData("a&b.pdf", "a_b.pdf")]
    public void Url_breaking_characters_replaced_with_underscore(string input, string expected)
        => Assert.Equal(expected, FilenameSanitizer.ToBlobSafe(input));

    [Theory]
    [InlineData("отчёт.pdf", ".pdf")]
    [InlineData("résumé.pdf", "r_sum_.pdf")]
    [InlineData("日本語.pdf", ".pdf")]
    public void Non_ascii_replaced_with_underscore(string input, string expected)
        => Assert.Equal(expected, FilenameSanitizer.ToBlobSafe(input));

    [Theory]
    [InlineData("a   b.pdf", "a_b.pdf")]
    [InlineData("a???b.pdf", "a_b.pdf")]
    [InlineData("a !@# b.pdf", "a_b.pdf")]
    public void Runs_of_unsafe_characters_collapse_to_single_underscore(string input, string expected)
        => Assert.Equal(expected, FilenameSanitizer.ToBlobSafe(input));

    [Theory]
    [InlineData("../etc/passwd", "passwd")]
    [InlineData("..\\..\\boot.ini", "boot.ini")]
    [InlineData("/abs/path/file.txt", "file.txt")]
    public void Directory_traversal_stripped_to_last_segment(string input, string expected)
        => Assert.Equal(expected, FilenameSanitizer.ToBlobSafe(input));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    [InlineData("???")]
    [InlineData("___")]
    [InlineData(".")]
    [InlineData("..")]
    public void Empty_or_all_unsafe_falls_back_to_default(string? input)
        => Assert.Equal("file", FilenameSanitizer.ToBlobSafe(input));

    [Fact]
    public void Length_capped_at_200_with_short_extension_preserved()
    {
        var input = new string('a', 500) + ".pdf";
        var result = FilenameSanitizer.ToBlobSafe(input);
        Assert.Equal(200, result.Length);
        Assert.EndsWith(".pdf", result);
    }

    [Fact]
    public void Length_capped_at_200_when_no_extension()
    {
        var input = new string('a', 500);
        var result = FilenameSanitizer.ToBlobSafe(input);
        Assert.Equal(200, result.Length);
        Assert.DoesNotContain('.', result);
    }

    [Fact]
    public void Length_capped_at_200_when_extension_too_long()
    {
        // 30-char "extension" looks more like a stem typo than a real extension — plain cut.
        var input = new string('a', 300) + "." + new string('b', 30);
        var result = FilenameSanitizer.ToBlobSafe(input);
        Assert.Equal(200, result.Length);
        Assert.StartsWith("aaa", result);
    }

    [Fact]
    public void Leading_and_trailing_underscores_trimmed()
    {
        Assert.Equal("a.pdf", FilenameSanitizer.ToBlobSafe("???a.pdf???"));
    }

    [Fact]
    public void Dots_preserved_so_extension_survives_when_stem_collapses()
    {
        Assert.Equal(".pdf", FilenameSanitizer.ToBlobSafe("日本語.pdf"));
    }
}
