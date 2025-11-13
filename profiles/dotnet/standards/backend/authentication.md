## Authentication and Authorization

### JWT Bearer Token Authentication

- **JWT Tokens**: Implement JWT bearer token authentication using Microsoft.AspNetCore.Authentication.JwtBearer for stateless API authentication with claims-based authorization model
- **Token Configuration**: Configure JWT token validation parameters including issuer, audience, signing key, clock skew, and token lifetime in authentication middleware setup
- **Token Generation**: Generate JWT tokens on successful authentication including user claims, role information, and custom claims for authorization decisions
- **Token Refresh**: Implement refresh token flow for long-lived sessions allowing clients to obtain new access tokens without re-authenticating with credentials
- **Token Storage**: Store tokens securely on client side using httpOnly cookies for web applications preventing JavaScript access and mitigating XSS vulnerabilities

### Claims-Based Authorization

- **Claims Definition**: Define claims representing user attributes (email, roles, permissions) to be included in JWT tokens for use in authorization decisions
- **Policy-Based Checks**: Use claims-based authorization with policy-based checks defining authorization policies in startup that evaluate user claims for access control decisions
- **Custom Policies**: Create custom authorization policies with `IAuthorizationRequirement` and `IAuthorizationHandler` for complex authorization logic based on multiple claims
- **Policy Evaluation**: Apply authorization policies to endpoints using `[Authorize]` and `[Authorize(Policy = "PolicyName")]` attributes for declarative access control

### Attribute-Based Authorization

- **Authorize Attributes**: Apply `[Authorize]` attributes on controllers and actions specifying required roles, policies, or authentication schemes for endpoint-level authorization enforcement
- **Anonymous Access**: Use `[AllowAnonymous]` attribute to allow unauthenticated access to specific endpoints overriding controller-level authorization requirements
- **Role-Based Access**: Use `[Authorize(Roles = "Admin,Moderator")]` for role-based access control allowing only users in specified roles to access endpoints

### User Context Access

- **HttpContext User**: Access current user claims through `HttpContext.User` in controllers containing `ClaimsPrincipal` with authenticated user information
- **Dependency Injection**: Inject `IHttpContextAccessor` in services requiring user context outside controller scope allowing access to current user claims in application services
- **Current User Service**: Create `ICurrentUserService` interface and implementation wrapping `IHttpContextAccessor` providing convenient access to current user properties throughout application
- **User ID Extraction**: Extract current user ID and roles from claims for use in queries ensuring users can only access their own data where applicable

### OpenID Connect Integration

- **OIDC Support**: Support OpenID Connect flows for web applications using Microsoft.AspNetCore.Authentication.OpenIdConnect for integration with identity providers like Azure AD
- **Provider Configuration**: Configure OIDC provider endpoints including authorization, token, and userinfo endpoints for identity provider communication
- **Scope Requests**: Request appropriate OIDC scopes (openid, profile, email) from identity provider to obtain necessary user claims in ID tokens
- **Token Exchange**: Exchange authorization code for tokens after user authentication completing OIDC flow securely

### API Key Authentication

- **Supplementary Authentication**: Consider API key authentication for service-to-service communication or webhook endpoints requiring simple token-based authentication without full OAuth flow
- **API Key Headers**: Accept API keys via `X-API-Key` header on API requests validating against registered API keys in database
- **Key Management**: Rotate API keys periodically and revoke compromised keys immediately limiting exposure of leaked credentials
- **Endpoint Restriction**: Restrict API key authentication to specific endpoints not requiring full user context validating only that caller has valid API key

### CORS Configuration

- **CORS Policy**: Configure CORS policy appropriately for browser-based clients specifying allowed origins, methods, headers, and credentials based on security requirements
- **Specific Origins**: Whitelist specific origin domains rather than allowing all origins via `*` preventing unauthorized cross-origin requests
- **Credential Support**: Allow credentials (cookies, tokens) in cross-origin requests only when necessary using `AllowCredentials()` carefully
- **Method Restrictions**: Specify allowed HTTP methods (GET, POST, etc.) limiting cross-origin requests to intended operation types
- **Header Restrictions**: Specify allowed request and response headers limiting data exposed in cross-origin requests

### Authentication Setup Example

```csharp
// Program.cs
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = builder.Configuration["Auth:Authority"];
        options.Audience = builder.Configuration["Auth:Audience"];
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuerSigningKey = true,
            ValidIssuer = builder.Configuration["Auth:Issuer"],
            ValidAudience = builder.Configuration["Auth:Audience"],
            ClockSkew = TimeSpan.FromMinutes(5)
        };
    });

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("AdminOnly", policy =>
        policy.RequireClaim(ClaimTypes.Role, "Admin"));
    
    options.AddPolicy("EmailConfirmed", policy =>
        policy.RequireClaim("email_verified", "true"));
});

builder.Services.AddScoped<ICurrentUserService, CurrentUserService>();

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();

// CurrentUserService.cs
public interface ICurrentUserService
{
    Guid UserId { get; }
    string? Email { get; }
    IEnumerable<string> Roles { get; }
}

public class CurrentUserService : ICurrentUserService
{
    private readonly IHttpContextAccessor _httpContextAccessor;
    
    public CurrentUserService(IHttpContextAccessor httpContextAccessor)
    {
        _httpContextAccessor = httpContextAccessor;
    }
    
    public Guid UserId =>
        Guid.Parse(_httpContextAccessor.HttpContext?.User
            .FindFirst(ClaimTypes.NameIdentifier)?.Value ?? Guid.Empty.ToString());
    
    public string? Email =>
        _httpContextAccessor.HttpContext?.User
            .FindFirst(ClaimTypes.Email)?.Value;
    
    public IEnumerable<string> Roles =>
        _httpContextAccessor.HttpContext?.User
            .FindAll(ClaimTypes.Role)
            .Select(c => c.Value) ?? Enumerable.Empty<string>();
}
```
