using Dotbot.Server.Services;
using System.Security.Claims;

namespace Dotbot.Server;

/// <summary>
/// Intercepts requests to / and /api/dashboard/* routes.
/// After authentication, checks the user's email against the administrator list.
/// Returns 403 if the user is not an administrator.
/// </summary>
public class DashboardAuthMiddleware
{
    private readonly RequestDelegate _next;

    public DashboardAuthMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context, IAdministratorService adminService)
    {
        var path = context.Request.Path.Value ?? "";

        var isDashboardRoute = path == "/"
            || path.StartsWith("/api/dashboard/", StringComparison.OrdinalIgnoreCase);

        if (!isDashboardRoute)
        {
            await _next(context);
            return;
        }

        if (context.User.Identity?.IsAuthenticated != true)
        {
            // Let the OIDC challenge handle unauthenticated users
            await _next(context);
            return;
        }

        var email = context.User.FindFirstValue(ClaimTypes.Email)
            ?? context.User.FindFirstValue("preferred_username")
            ?? context.User.FindFirstValue("email");

        if (string.IsNullOrEmpty(email))
        {
            context.Response.StatusCode = 403;
            context.Response.ContentType = "text/plain";
            await context.Response.WriteAsync("Access denied: could not determine your email address.");
            return;
        }

        if (!await adminService.IsAdministratorAsync(email))
        {
            context.Response.StatusCode = 403;
            context.Response.ContentType = "text/plain";
            await context.Response.WriteAsync($"Access denied: {email} is not an administrator.");
            return;
        }

        await _next(context);
    }
}
