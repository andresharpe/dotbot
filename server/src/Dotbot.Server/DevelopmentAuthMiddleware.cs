using System.Security.Claims;

namespace Dotbot.Server;

/// <summary>
/// In Development environment, sets HttpContext.User to a synthetic identity
/// so dashboard pages and APIs work without real Azure AD sign-in.
/// </summary>
public class DevelopmentAuthMiddleware
{
    private readonly RequestDelegate _next;

    public DevelopmentAuthMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (context.User.Identity?.IsAuthenticated != true)
        {
            var claims = new[]
            {
                new Claim(ClaimTypes.Name, "Developer"),
                new Claim(ClaimTypes.Email, "dev@localhost"),
                new Claim("preferred_username", "dev@localhost"),
                new Claim(ClaimTypes.NameIdentifier, "dev-local")
            };
            var identity = new ClaimsIdentity(claims, "Development");
            context.User = new ClaimsPrincipal(identity);
        }

        await _next(context);
    }
}
