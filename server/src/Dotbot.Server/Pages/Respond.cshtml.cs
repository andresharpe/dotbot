using Dotbot.Server.Models;
using Dotbot.Server.Services;
using Dotbot.Server.Validation;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using System.IdentityModel.Tokens.Jwt;
using System.Text.Json;

namespace Dotbot.Server.Pages;

[IgnoreAntiforgeryToken]
[RequestSizeLimit(35 * 1024 * 1024)]
public class RespondModel : PageModel
{
    private static readonly string[] AllowedExtensions = [".md", ".docx", ".xlsx", ".pdf", ".txt"];
    private const long MaxFileBytes = 15 * 1024 * 1024; // 15 MB

    private static readonly JsonSerializerOptions RankedItemsJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    private readonly IInstanceStorageService _instances;
    private readonly ITemplateStorageService _templates;
    private readonly ResponseStorageService _responses;
    private readonly AttachmentStorageService _attachments;
    private readonly ITokenStorageService _tokenStorage;
    private readonly AuthSettings _authSettings;
    private readonly ILogger<RespondModel> _logger;

    public RespondModel(
        IInstanceStorageService instances,
        ITemplateStorageService templates,
        ResponseStorageService responses,
        AttachmentStorageService attachments,
        ITokenStorageService tokenStorage,
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

    /// <summary>
    /// Magic-link JWT propagated from the GET query string, used by the page to construct
    /// signed download URLs for blob-stored review attachments. Null when the user is on a
    /// device cookie — PR-8 introduces a dedicated download-token mint for that path.
    /// </summary>
    public string? AttachmentDownloadToken { get; set; }

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

        if (!string.IsNullOrEmpty(token))
        {
            try
            {
                var handler = new JwtSecurityTokenHandler();
                var jwt = handler.ReadJwtToken(token);
                instanceIdStr ??= jwt.Claims.FirstOrDefault(c => c.Type == "questionInstanceId")?.Value;
                projId ??= jwt.Claims.FirstOrDefault(c => c.Type == "projectId")?.Value;
                AttachmentDownloadToken = token;
            }
            catch
            {
                // Token unreadable; fall through to query params
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

    public async Task<IActionResult> OnPostAsync(
        Guid instanceId,
        string projectId,
        Guid questionId,
        string? selectedKey,
        string? freeText,
        string? approvalDecision,
        string? comment,
        string? rankedItemsJson)
    {
        var attachments = Request.Form.Files;
        var reviewedIds = ParseReviewedIds(Request.Form["reviewedAttachmentIds"]);
        var rankedItems = ParseRankedItems(rankedItemsJson);

        // Filter uploads up front so validation, save loop, and confirmation label all see the
        // same accepted set. Submitting only disallowed/oversized files must not pass an
        // "attachment-only" check and consume the magic link with an empty response.
        var acceptedFiles = new List<IFormFile>(attachments.Count);
        foreach (var file in attachments)
        {
            var ext = Path.GetExtension(file.FileName).ToLowerInvariant();
            var safeName = Path.GetFileName(file.FileName);
            if (string.IsNullOrWhiteSpace(safeName))
            {
                _logger.LogWarning("Skipping attachment: empty filename");
                continue;
            }
            if (!AllowedExtensions.Contains(ext))
            {
                _logger.LogWarning("Skipping attachment {Name}: unsupported extension {Ext}", safeName, ext);
                continue;
            }
            if (file.Length > MaxFileBytes)
            {
                _logger.LogWarning("Skipping attachment {Name}: exceeds 15 MB limit ({Size} bytes)", safeName, file.Length);
                continue;
            }
            acceptedFiles.Add(file);
        }

        _logger.LogDebug(
            "POST Respond: instanceId={InstanceId}, selectedKey={SelectedKey}, decision={Decision}, reviewed={ReviewedCount}, ranked={RankedCount}, uploadedCount={UploadedCount}, acceptedCount={AcceptedCount}",
            instanceId, selectedKey, approvalDecision, reviewedIds.Count, rankedItems.Count, attachments.Count, acceptedFiles.Count);

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

        var input = new RespondFormInput(
            SelectedKey: selectedKey,
            FreeText: freeText,
            ApprovalDecision: approvalDecision,
            Comment: comment,
            ReviewedAttachmentIds: reviewedIds,
            RankedItems: rankedItems,
            UploadedAttachmentCount: acceptedFiles.Count);

        var validation = RespondFormHandler.Validate(template, input);
        if (!validation.IsValid)
        {
            ErrorMessage = validation.Error;
            InstanceId = instanceId;
            ProjectId = projectId;
            Template = template;
            AllowFreeText = template.ResponseSettings?.AllowFreeText ?? false;
            return Page();
        }

        var responseId = Guid.NewGuid();

        var savedAttachments = new List<AttachmentRecord>();
        if (QuestionTypes.SupportsAttachments(template.Type))
        {
            foreach (var file in acceptedFiles)
            {
                var safeFileName = Path.GetFileName(file.FileName);
                using var stream = file.OpenReadStream();
                var record = await _attachments.SaveAsync(responseId, safeFileName, stream, file.Length);
                savedAttachments.Add(record);
                _logger.LogInformation("Attachment saved: {BlobPath} ({Size} bytes)", record.BlobPath, record.SizeBytes);
            }
        }
        else if (acceptedFiles.Count > 0)
        {
            _logger.LogWarning(
                "Ignoring {Count} attachment(s) for question type {Type}: no upload UI is rendered for this type",
                acceptedFiles.Count, template.Type);
        }

        var response = new ResponseRecordV2
        {
            ResponseId = responseId,
            InstanceId = instanceId,
            QuestionId = instance.QuestionId,
            QuestionVersion = instance.QuestionVersion,
            ProjectId = instance.ProjectId,
            ResponderEmail = email,
            SelectedOptionId = validation.SelectedOptionId,
            SelectedKey = validation.SelectedKey,
            SelectedOptionTitle = validation.SelectedOptionTitle,
            FreeText = validation.FreeText,
            ApprovalDecision = validation.ApprovalDecision,
            Comment = validation.Comment,
            ReviewedAttachmentIds = validation.ReviewedAttachmentIds?.ToList(),
            RankedItems = validation.RankedItems?.ToList(),
            Attachments = savedAttachments.Count > 0 ? savedAttachments : null,
            AnsweredVia = "notification"
        };

        var (_, _) = await _responses.SaveResponseAsync(response);
        _logger.LogInformation(
            "Web response saved: type={Type}, responder={Email}, instance={InstanceId}, decision={Decision}, key={Key}",
            template.Type, email, instanceId, response.ApprovalDecision, response.SelectedKey);

        await ConsumeMagicLinkAsync(email);

        var selectionLabel = validation.SelectionLabel ?? "Custom response";
        return RedirectToPage("Confirmation", new { question = template.Title, selection = selectionLabel });
    }

    private static List<Guid> ParseReviewedIds(Microsoft.Extensions.Primitives.StringValues raw)
    {
        var ids = new List<Guid>();
        foreach (var value in raw)
        {
            if (string.IsNullOrWhiteSpace(value)) continue;
            if (Guid.TryParse(value, out var id)) ids.Add(id);
        }
        return ids;
    }

    private static List<RankedItem> ParseRankedItems(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new List<RankedItem>();
        try
        {
            var parsed = JsonSerializer.Deserialize<List<RankedItem>>(json, RankedItemsJsonOptions);
            return parsed ?? new List<RankedItem>();
        }
        catch (JsonException)
        {
            return new List<RankedItem>();
        }
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
