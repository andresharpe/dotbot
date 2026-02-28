using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using System.IdentityModel.Tokens.Jwt;

namespace Dotbot.Server.Pages;

[IgnoreAntiforgeryToken]
public class RespondModel : PageModel
{
    private readonly InstanceStorageService _instances;
    private readonly TemplateStorageService _templates;
    private readonly ResponseStorageService _responses;
    private readonly TokenStorageService _tokenStorage;
    private readonly AuthSettings _authSettings;
    private readonly ILogger<RespondModel> _logger;

    public RespondModel(
        InstanceStorageService instances,
        TemplateStorageService templates,
        ResponseStorageService responses,
        TokenStorageService tokenStorage,
        IOptions<AuthSettings> authSettings,
        ILogger<RespondModel> logger)
    {
        _instances = instances;
        _templates = templates;
        _responses = responses;
        _tokenStorage = tokenStorage;
        _authSettings = authSettings.Value;
        _logger = logger;
    }

    public QuestionTemplate? Template { get; set; }
    public Guid InstanceId { get; set; }
    public string? ProjectId { get; set; }
    public bool AllowFreeText { get; set; }
    public string? ErrorMessage { get; set; }

    public async Task<IActionResult> OnGetAsync([FromQuery] string? token, [FromQuery] string? instanceId, [FromQuery] string? projectId)
    {
        var email = HttpContext.Items["AuthenticatedEmail"] as string;
        if (string.IsNullOrEmpty(email))
        {
            ErrorMessage = "Authentication required.";
            return Page();
        }

        string? instanceIdStr = instanceId;
        string? projId = projectId;

        // Extract claims from magic link JWT if present
        if (!string.IsNullOrEmpty(token))
        {
            try
            {
                var handler = new JwtSecurityTokenHandler();
                var jwt = handler.ReadJwtToken(token);
                instanceIdStr ??= jwt.Claims.FirstOrDefault(c => c.Type == "questionInstanceId")?.Value;
                projId ??= jwt.Claims.FirstOrDefault(c => c.Type == "projectId")?.Value;
            }
            catch
            {
                // Token was already consumed by middleware; fall through to query params
            }
        }

        if (!Guid.TryParse(instanceIdStr, out var parsedInstanceId) || string.IsNullOrEmpty(projId))
        {
            ErrorMessage = "No question instance specified.";
            return Page();
        }

        InstanceId = parsedInstanceId;
        ProjectId = projId;

        var instance = await _instances.GetInstanceAsync(projId, parsedInstanceId);
        if (instance is null)
        {
            ErrorMessage = "Question not found or has been closed.";
            return Page();
        }

        var template = await _templates.GetTemplateAsync(instance.ProjectId, instance.QuestionId, instance.QuestionVersion);
        if (template is null)
        {
            ErrorMessage = "Question template not found.";
            return Page();
        }

        Template = template;
        AllowFreeText = template.ResponseSettings?.AllowFreeText ?? false;
        return Page();
    }

    public async Task<IActionResult> OnPostAsync(Guid instanceId, string projectId, Guid questionId, string selectedKey, string? freeText)
    {
        _logger.LogDebug("POST received: instanceId={InstanceId}, projectId={ProjectId}, questionId={QuestionId}, selectedKey={SelectedKey}",
            instanceId, projectId, questionId, selectedKey);

        var email = HttpContext.Items["AuthenticatedEmail"] as string;
        if (string.IsNullOrEmpty(email))
        {
            ErrorMessage = "Authentication required.";
            return Page();
        }

        var instance = await _instances.GetInstanceAsync(projectId, instanceId);
        if (instance is null)
        {
            ErrorMessage = "Question instance not found.";
            return Page();
        }

        var template = await _templates.GetTemplateAsync(instance.ProjectId, instance.QuestionId, instance.QuestionVersion);
        if (template is null)
        {
            ErrorMessage = "Question template not found.";
            return Page();
        }

        _logger.LogInformation("Template option keys: [{Keys}]",
            string.Join(", ", template.Options.Select(o => $"'{o.Key}'")));

        var selectedOption = template.Options.FirstOrDefault(o => o.Key == selectedKey);
        if (selectedOption is null)
        {
            ErrorMessage = "Invalid selection.";
            InstanceId = instanceId;
            ProjectId = projectId;
            Template = template;
            AllowFreeText = template.ResponseSettings?.AllowFreeText ?? false;
            return Page();
        }

        var response = new ResponseRecordV2
        {
            ResponseId = Guid.NewGuid(),
            InstanceId = instanceId,
            QuestionId = instance.QuestionId,
            QuestionVersion = instance.QuestionVersion,
            ProjectId = instance.ProjectId,
            ResponderEmail = email,
            SelectedOptionId = selectedOption.OptionId,
            SelectedKey = selectedKey,
            SelectedOptionTitle = selectedOption.Title,
            FreeText = freeText
        };

        await _responses.SaveResponseAsync(response);
        _logger.LogInformation("Web response saved for {Email}, instance {InstanceId}, key {Key}", email, instanceId, selectedKey);

        // Consume the magic link token now that the response has been saved successfully
        await ConsumeMagicLinkAsync(email);

        return RedirectToPage("Confirmation", new { question = template.Title, selection = $"{selectedKey}. {selectedOption.Title}" });
    }

    /// <summary>
    /// Consumes the magic link and creates a device cookie so the user can revisit without a new link.
    /// Called only after the response has been persisted successfully.
    /// </summary>
    private async Task ConsumeMagicLinkAsync(string email)
    {
        if (HttpContext.Items["MagicLinkJti"] is not string jti)
            return;

        var deviceTokenId = Guid.NewGuid().ToString();
        var deviceToken = new DeviceToken
        {
            DeviceTokenId = deviceTokenId,
            Email = email,
            ExpiresAt = DateTime.UtcNow.AddDays(_authSettings.DeviceTokenExpiryDays),
            UserAgent = Request.Headers.UserAgent.ToString(),
            IpAddress = HttpContext.Connection.RemoteIpAddress?.ToString()
        };

        var marked = await _tokenStorage.TryMarkMagicLinkUsedAsync(jti, deviceTokenId);
        if (!marked)
        {
            _logger.LogWarning("Magic link {Jti} was consumed by another request (race condition)", jti);
            return;
        }

        await _tokenStorage.SaveDeviceTokenAsync(deviceToken);

        Response.Cookies.Append(_authSettings.CookieName, deviceTokenId, new CookieOptions
        {
            HttpOnly = true,
            Secure = true,
            SameSite = SameSiteMode.Lax,
            MaxAge = TimeSpan.FromDays(_authSettings.DeviceTokenExpiryDays)
        });

        _logger.LogInformation("Magic link consumed after successful submit for {Email}, device token {DeviceTokenId}", email, deviceTokenId);
    }
}
