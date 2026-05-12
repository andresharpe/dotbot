using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using System.IdentityModel.Tokens.Jwt;

namespace Dotbot.Server.Pages;

[IgnoreAntiforgeryToken]
[RequestSizeLimit(35 * 1024 * 1024)]
public class RespondModel : PageModel
{
    private static readonly string[] AllowedExtensions = [".md", ".docx", ".xlsx", ".pdf", ".txt", ".png", ".jpg", ".jpeg"];
    private const long MaxFileBytes = 15 * 1024 * 1024; // 15 MB

    private readonly InstanceStorageService _instances;
    private readonly ITemplateStorageService _templates;
    private readonly ResponseStorageService _responses;
    private readonly AttachmentStorageService _attachments;
    private readonly TokenStorageService _tokenStorage;
    private readonly AuthSettings _authSettings;
    private readonly ILogger<RespondModel> _logger;

    public RespondModel(
        InstanceStorageService instances,
        ITemplateStorageService templates,
        ResponseStorageService responses,
        AttachmentStorageService attachments,
        TokenStorageService tokenStorage,
        IOptions<AuthSettings> authSettings,
        ILogger<RespondModel> logger)
    {
        _instances = instances;
        _templates = templates;
        _responses = responses;
        _attachments = attachments;
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

    public async Task<IActionResult> OnPostAsync(Guid instanceId, string projectId, Guid questionId, string? selectedKey, string? freeText)
    {
        var attachments = Request.Form.Files;
        _logger.LogDebug("POST Respond: instanceId={InstanceId}, selectedKey={SelectedKey}, attachmentCount={AttachmentCount}",
            instanceId, selectedKey, attachments.Count);

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

        // Resolve selected option (may be null for attachment-only submissions)
        var selectedOption = string.IsNullOrEmpty(selectedKey)
            ? null
            : template.Options.FirstOrDefault(o => o.Key == selectedKey);

        if (!string.IsNullOrEmpty(selectedKey) && selectedOption is null)
        {
            ErrorMessage = "Invalid selection.";
            InstanceId = instanceId;
            ProjectId = projectId;
            Template = template;
            AllowFreeText = template.ResponseSettings?.AllowFreeText ?? false;
            return Page();
        }

        var hasAttachments = attachments.Count > 0;
        if (selectedOption is null && string.IsNullOrWhiteSpace(freeText) && !hasAttachments)
        {
            ErrorMessage = "Please select an option, type a response, or attach a file.";
            InstanceId = instanceId;
            ProjectId = projectId;
            Template = template;
            AllowFreeText = template.ResponseSettings?.AllowFreeText ?? false;
            return Page();
        }

        var responseId = Guid.NewGuid();

        // Save attachments to blob storage
        var savedAttachments = new List<AttachmentRecord>();
        if (attachments.Count > 0)
        {
            foreach (var file in attachments)
            {
                var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
                if (!AllowedExtensions.Contains(ext))
                {
                    _logger.LogWarning("Skipping attachment {Name}: unsupported extension {Ext}", file.FileName, ext);
                    continue;
                }
                if (file.Length > MaxFileBytes)
                {
                    _logger.LogWarning("Skipping attachment {Name}: exceeds 15 MB limit ({Size} bytes)", file.FileName, file.Length);
                    continue;
                }

                var safeFileName = Path.GetFileName(file.FileName);
                if (string.IsNullOrWhiteSpace(safeFileName)) continue;
                using var stream = file.OpenReadStream();
                var record = await _attachments.SaveAsync(responseId, safeFileName, stream, file.Length);
                savedAttachments.Add(record);
                _logger.LogInformation("Attachment saved: {BlobPath} ({Size} bytes)", record.BlobPath, record.SizeBytes);
            }
        }

        var response = new ResponseRecordV2
        {
            ResponseId = responseId,
            InstanceId = instanceId,
            QuestionId = instance.QuestionId,
            QuestionVersion = instance.QuestionVersion,
            ProjectId = instance.ProjectId,
            ResponderEmail = email,
            SelectedOptionId = selectedOption?.OptionId,
            SelectedKey = selectedKey,
            SelectedOptionTitle = selectedOption?.Title,
            FreeText = freeText,
            Attachments = savedAttachments.Count > 0 ? savedAttachments : null
        };

        await _responses.SaveResponseAsync(response);
        _logger.LogInformation("Web response saved for {Email}, instance {InstanceId}, key {Key}", email, instanceId, selectedKey);

        // Consume the magic link token now that the response has been saved successfully
        await ConsumeMagicLinkAsync(email);

        var selectionLabel = selectedOption is not null
            ? $"{selectedKey}. {selectedOption.Title}"
            : savedAttachments.Count > 0 ? $"{savedAttachments.Count} file(s) attached" : "Custom response";
        return RedirectToPage("Confirmation", new { question = template.Title, selection = selectionLabel });
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
