using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace Dotbot.Server.Pages;

public class ConfirmationModel : PageModel
{
    public string? Question { get; set; }
    public string? Selection { get; set; }

    public void OnGet([FromQuery] string? question, [FromQuery] string? selection)
    {
        Question = question;
        Selection = selection;
    }
}
