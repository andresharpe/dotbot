using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.RazorPages;
using System.Security.Claims;

namespace Dotbot.Server.Pages;

[Authorize]
public class IndexModel : PageModel
{
    public string UserEmail { get; private set; } = "";
    public string UserName { get; private set; } = "";

    public void OnGet()
    {
        UserEmail = User.FindFirstValue(ClaimTypes.Email)
            ?? User.FindFirstValue("preferred_username")
            ?? User.FindFirstValue("email")
            ?? "unknown";
        UserName = User.FindFirstValue(ClaimTypes.Name)
            ?? User.FindFirstValue("name")
            ?? UserEmail;
    }
}
