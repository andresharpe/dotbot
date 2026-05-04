using Dotbot.Server.Models;
using Microsoft.Agents.Authentication;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Hosting.AspNetCore;
using System.Net;
using System.Text;
using System.Text.Json;

namespace Dotbot.Server.Services.Delivery;

public class TeamsDeliveryProvider : IQuestionDeliveryProvider
{
    private readonly ConversationReferenceStore _convoStore;
    private readonly AdaptiveCardService _cardService;
    private readonly GraphTokenService _graphTokenService;
    private readonly IAgentHttpAdapter _adapter;
    private readonly IConfiguration _config;
    private readonly ILogger<TeamsDeliveryProvider> _logger;

    public string ChannelName => "teams";

    public TeamsDeliveryProvider(
        ConversationReferenceStore convoStore,
        AdaptiveCardService cardService,
        GraphTokenService graphTokenService,
        IAgentHttpAdapter adapter,
        IConfiguration config,
        ILogger<TeamsDeliveryProvider> logger)
    {
        _convoStore = convoStore;
        _cardService = cardService;
        _graphTokenService = graphTokenService;
        _adapter = adapter;
        _config = config;
        _logger = logger;
    }

    public async Task<DeliveryResult> DeliverAsync(DeliveryContext context, CancellationToken ct)
    {
        var userId = context.Recipient.AadObjectId;
        if (string.IsNullOrEmpty(userId))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = ChannelName,
                ErrorMessage = "No AAD object ID for recipient"
            };
        }

        var reference = _convoStore.Get(userId);
        var isNewUser = reference is null;
        if (reference is null)
        {
            _logger.LogInformation(
                "No conversation reference for {UserId}, attempting proactive install", userId);

            await ProactiveInstallAndCreateConversationAsync(userId, ct);
            reference = _convoStore.Get(userId);

            if (reference is null)
            {
                return new DeliveryResult
                {
                    Success = false,
                    Channel = ChannelName,
                    ErrorMessage = $"Failed to proactively install Teams app for user {userId}"
                };
            }
        }

        var template = context.Template;
        var opts = template.Options.Select(o => new QuestionOption
        {
            Key = o.Key,
            Label = o.Title,
            Rationale = o.Summary ?? o.Details?.Overview,
            OptionId = o.OptionId
        }).ToList();

        var allowFree = template.ResponseSettings?.AllowFreeText ?? false;

        var card = context.Summary is not null
            ? _cardService.CreateSummaryCard(context.Summary)
            : _cardService.CreateQuestionCard(
                template.QuestionId.ToString(), template.Title, opts, template.Context, allowFree,
                template.Project.Name, template.Project.Description,
                context.Instance.InstanceId.ToString(), context.MagicLinkUrl,
                template.Project.ProjectId, template.Version);

        var attachment = new Attachment
        {
            ContentType = "application/vnd.microsoft.card.adaptive",
            Content = JsonSerializer.Deserialize<JsonElement>(card.ToJson())
        };

        var channelAdapter = (IChannelAdapter)_adapter;
        var botAppId = _config["TokenValidation:Audiences:0"] ?? "";
        var claimsIdentity = AgentClaims.CreateIdentity(botAppId);

        await channelAdapter.ContinueConversationAsync(
            claimsIdentity,
            reference,
            async (turnContext, innerCt) =>
            {
                if (isNewUser)
                {
                    var introCard = _cardService.CreateIntroCard();
                    var introAttachment = new Attachment
                    {
                        ContentType = "application/vnd.microsoft.card.adaptive",
                        Content = JsonSerializer.Deserialize<JsonElement>(introCard.ToJson())
                    };
                    await turnContext.SendActivityAsync(
                        MessageFactory.Attachment(introAttachment), innerCt);
                }
                var response = await turnContext.SendActivityAsync(
                    MessageFactory.Attachment(attachment), innerCt);

                // Set pending question after send so we can capture the card activity ID
                DotbotAgent.SetPendingQuestion(userId, new PendingQuestion
                {
                    InstanceId = context.Instance.InstanceId,
                    QuestionId = template.QuestionId,
                    Question = template.Title,
                    Options = opts,
                    AllowFreeText = allowFree,
                    ProjectId = template.Project.ProjectId,
                    QuestionVersion = template.Version,
                    CardActivityId = response?.Id,
                    ProjectName = template.Project.Name,
                    ProjectDescription = template.Project.Description,
                    Context = template.Context,
                    MagicLinkUrl = context.MagicLinkUrl
                });
            },
            ct);

        _logger.LogInformation("Delivered question to {UserId} via Teams", userId);
        return new DeliveryResult { Success = true, Channel = ChannelName };
    }

    private async Task ProactiveInstallAndCreateConversationAsync(string userId, CancellationToken ct)
    {
        var teamsAppId = _config["Teams:TeamsAppId"] ?? _config["TokenValidation:Audiences:0"] ?? "";
        var botAppId = _config["TokenValidation:Audiences:0"] ?? "";
        var serviceUrl = _config["Teams:ServiceUrl"] ?? "https://smba.trafficmanager.net/emea/";
        var tenantId = _config["TokenValidation:TenantId"] ?? "";

        // Step 1: Install the Teams app for the user via Graph API
        try
        {
            var client = await _graphTokenService.CreateAuthenticatedClientAsync();
            var installPayload = JsonSerializer.Serialize(new
            {
                teamsApp_odata_bind = $"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/{teamsAppId}"
            });
            // The JSON key needs to be "teamsApp@odata.bind" — serialize manually
            var installJson = $"{{\"teamsApp@odata.bind\":\"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/{teamsAppId}\"}}";

            var response = await client.PostAsync(
                $"https://graph.microsoft.com/v1.0/users/{userId}/teamwork/installedApps",
                new StringContent(installJson, Encoding.UTF8, "application/json"),
                ct);

            if (response.StatusCode == HttpStatusCode.Conflict)
            {
                _logger.LogInformation("Teams app already installed for user {UserId}", userId);
            }
            else if (response.IsSuccessStatusCode)
            {
                _logger.LogInformation("Proactively installed Teams app for user {UserId}", userId);
            }
            else
            {
                var body = await response.Content.ReadAsStringAsync(ct);
                _logger.LogError(
                    "Failed to install Teams app for user {UserId}: {Status} {Body}",
                    userId, response.StatusCode, body);
                return;
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error installing Teams app for user {UserId}", userId);
            return;
        }

        // Step 2: Create a 1:1 conversation via Bot Framework adapter
        try
        {
            var channelAdapter = (IChannelAdapter)_adapter;

            var parameters = new ConversationParameters
            {
                Agent = new ChannelAccount { Id = $"28:{botAppId}" },
                Members = new List<ChannelAccount>
                {
                    new() { Id = $"29:{userId}" }
                },
                ChannelData = new { tenant = new { id = tenantId } },
                TenantId = tenantId,
                IsGroup = false
            };

            await channelAdapter.CreateConversationAsync(
                botAppId,
                "msteams",
                serviceUrl,
                "https://api.botframework.com",
                parameters,
                (turnContext, innerCt) =>
                {
                    var convoRef = turnContext.Activity.GetConversationReference();
                    _convoStore.AddOrUpdate(userId, convoRef);
                    _logger.LogInformation(
                        "Created and stored conversation reference for user {UserId}", userId);
                    return Task.CompletedTask;
                },
                ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error creating conversation for user {UserId}", userId);
        }
    }
}
