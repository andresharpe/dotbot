using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.RazorPages;
using System.Security.Claims;

namespace Dotbot.Server.Pages;

// The cross-outpost Q&A dashboard — the "Decisions" rail slot. Re-homed from the
// site root (/) to /decisions in #547 so Fleet can become the landing surface.
[Authorize]
public class DecisionsModel : PageModel
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
