using Dotbot.Server.Models;

namespace Dotbot.Server.Services.Delivery;

public class DeliveryOrchestrator
{
    private readonly Dictionary<string, IQuestionDeliveryProvider> _providers;
    private readonly UserResolverService _userResolver;
    private readonly MagicLinkService _magicLinkService;
    private readonly BusinessHoursService _businessHours;
    private readonly IConfiguration _config;
    private readonly ILogger<DeliveryOrchestrator> _logger;

    public DeliveryOrchestrator(
        IEnumerable<IQuestionDeliveryProvider> providers,
        UserResolverService userResolver,
        MagicLinkService magicLinkService,
        BusinessHoursService businessHours,
        IConfiguration config,
        ILogger<DeliveryOrchestrator> logger)
    {
        _providers = providers.ToDictionary(p => p.ChannelName, StringComparer.OrdinalIgnoreCase);
        _userResolver = userResolver;
        _magicLinkService = magicLinkService;
        _businessHours = businessHours;
        _config = config;
        _logger = logger;
    }

    /// <summary>
    /// Returns the set of currently registered (enabled) delivery channel names.
    /// </summary>
    public IReadOnlyCollection<string> AvailableChannels => _providers.Keys;

    /// <summary>
    /// Returns true if the given channel name has a registered provider.
    /// </summary>
    public bool IsChannelAvailable(string channel) =>
        _providers.ContainsKey(channel);

    /// <summary>
    /// Delivers a question instance to all recipients via the specified channel.
    /// Returns the list of recipient results for storage in the instance.
    /// </summary>
    public async Task<List<InstanceRecipient>> DeliverToAllAsync(
        QuestionInstance instance,
        QuestionTemplate template,
        CreateInstanceRequest request,
        CancellationToken ct)
    {
        var channel = request.Channel ?? "teams";
        if (!_providers.TryGetValue(channel, out var provider))
        {
            throw new InvalidOperationException(
                $"Delivery channel '{channel}' is not available. Enabled channels: {string.Join(", ", _providers.Keys)}");
        }

        var baseUrl = GetBaseUrl();
        var recipients = new List<InstanceRecipient>();

        // Collect all target emails
        var emails = new List<string>(request.Recipients?.Emails ?? []);

        // For Teams, also resolve object IDs back (they stay as-is in ResolveUserIdAsync)
        var objectIdRecipients = request.Recipients?.UserObjectIds ?? [];

        foreach (var email in emails)
        {
            var recipientInfo = new RecipientInfo { Email = email };

            try
            {
                // Resolve to AAD object ID (needed for Teams delivery)
                if (channel == "teams")
                {
                    var aadId = await _userResolver.ResolveUserIdAsync(email);
                    recipientInfo.AadObjectId = aadId;
                }

                // Business hours check — defer if outside hours
                var userKey = recipientInfo.AadObjectId ?? email;
                if (!await _businessHours.IsWithinBusinessHoursAsync(userKey, channel))
                {
                    _logger.LogInformation("Scheduling delivery to {Email} — outside business hours", email);
                    recipients.Add(new InstanceRecipient
                    {
                        Email = email,
                        AadObjectId = recipientInfo.AadObjectId,
                        Channel = channel,
                        Status = "scheduled",
                        ScheduledAt = DateTime.UtcNow
                    });
                    continue;
                }

                // Resolve display name for email channel (non-critical)
                if (channel == "email")
                {
                    try
                    {
                        recipientInfo.DisplayName = await _userResolver.ResolveDisplayNameAsync(email);
                    }
                    catch (Exception ex)
                    {
                        _logger.LogWarning(ex, "Could not resolve display name for {Email}", email);
                    }
                }

                // Generate magic link
                var magicLinkUrl = await _magicLinkService.GenerateMagicLinkAsync(
                    email, instance.InstanceId, instance.ProjectId, baseUrl);

                var deliveryContext = new DeliveryContext
                {
                    Instance = instance,
                    Template = template,
                    Recipient = recipientInfo,
                    MagicLinkUrl = magicLinkUrl,
                    JiraIssueKey = request.JiraIssueKey
                };

                var result = await provider.DeliverAsync(deliveryContext, ct);

                recipients.Add(new InstanceRecipient
                {
                    Email = email,
                    AadObjectId = recipientInfo.AadObjectId,
                    Channel = channel,
                    SentAt = result.Success ? DateTime.UtcNow : null,
                    Status = result.Success ? "sent" : "failed"
                });
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to deliver to {Email} via {Channel}", email, channel);
                recipients.Add(new InstanceRecipient
                {
                    Email = email,
                    Channel = channel,
                    Status = "failed"
                });
            }
        }

        // Handle Slack user ID recipients
        var slackUserIds = request.Recipients?.SlackUserIds ?? [];
        if (channel == "slack")
        {
            foreach (var slackUserId in slackUserIds)
            {
                var recipientInfo = new RecipientInfo { Email = slackUserId, SlackUserId = slackUserId };

                try
                {
                    var magicLinkUrl = await _magicLinkService.GenerateMagicLinkAsync(
                        slackUserId, instance.InstanceId, instance.ProjectId, baseUrl);

                    var deliveryContext = new DeliveryContext
                    {
                        Instance = instance,
                        Template = template,
                        Recipient = recipientInfo,
                        MagicLinkUrl = magicLinkUrl,
                        JiraIssueKey = request.JiraIssueKey
                    };

                    var result = await provider.DeliverAsync(deliveryContext, ct);

                    recipients.Add(new InstanceRecipient
                    {
                        SlackUserId = slackUserId,
                        Channel = channel,
                        SentAt = result.Success ? DateTime.UtcNow : null,
                        Status = result.Success ? "sent" : "failed"
                    });
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to deliver to Slack user {SlackUserId}", slackUserId);
                    recipients.Add(new InstanceRecipient { SlackUserId = slackUserId, Channel = channel, Status = "failed" });
                }
            }
        }

        // Handle raw object ID recipients (Teams only)
        foreach (var userId in objectIdRecipients)
        {
            var recipientInfo = new RecipientInfo { Email = userId, AadObjectId = userId };

            try
            {
                // Business hours check — defer if outside hours
                if (!await _businessHours.IsWithinBusinessHoursAsync(userId, channel))
                {
                    _logger.LogInformation("Scheduling delivery to {UserId} — outside business hours", userId);
                    recipients.Add(new InstanceRecipient
                    {
                        AadObjectId = userId,
                        Channel = channel,
                        Status = "scheduled",
                        ScheduledAt = DateTime.UtcNow
                    });
                    continue;
                }

                var magicLinkUrl = await _magicLinkService.GenerateMagicLinkAsync(
                    userId, instance.InstanceId, instance.ProjectId, baseUrl);

                var deliveryContext = new DeliveryContext
                {
                    Instance = instance,
                    Template = template,
                    Recipient = recipientInfo,
                    MagicLinkUrl = magicLinkUrl,
                    JiraIssueKey = request.JiraIssueKey
                };

                var result = await provider.DeliverAsync(deliveryContext, ct);

                recipients.Add(new InstanceRecipient
                {
                    AadObjectId = userId,
                    Channel = channel,
                    SentAt = result.Success ? DateTime.UtcNow : null,
                    Status = result.Success ? "sent" : "failed"
                });
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to deliver to {UserId} via {Channel}", userId, channel);
                recipients.Add(new InstanceRecipient
                {
                    AadObjectId = userId,
                    Channel = channel,
                    Status = "failed"
                });
            }
        }

        return recipients;
    }

    /// <summary>
    /// Delivers a reminder to a single recipient.
    /// Returns a result with Channel = "outside_business_hours" if the recipient
    /// is outside business hours and delivery should be deferred.
    /// </summary>
    public async Task<DeliveryResult> DeliverReminderAsync(
        QuestionInstance instance,
        QuestionTemplate template,
        InstanceRecipient recipient,
        CancellationToken ct)
    {
        var channel = recipient.Channel ?? "teams";

        // Business hours check — defer reminder if outside hours
        var userKey = recipient.AadObjectId ?? recipient.Email ?? recipient.SlackUserId ?? "";
        if (!await _businessHours.IsWithinBusinessHoursAsync(userKey, channel))
        {
            _logger.LogDebug("Deferring reminder for {Recipient} — outside business hours",
                recipient.Email ?? recipient.AadObjectId);
            return new DeliveryResult
            {
                Success = false,
                Channel = "outside_business_hours"
            };
        }

        if (!_providers.TryGetValue(channel, out var provider))
        {
            return new DeliveryResult
            {
                Success = false,
                Channel = channel,
                ErrorMessage = $"Unknown channel: {channel}"
            };
        }

        var baseUrl = GetBaseUrl();
        var email = recipient.SlackUserId ?? recipient.Email ?? recipient.AadObjectId ?? "";
        var magicLinkUrl = await _magicLinkService.GenerateMagicLinkAsync(
            email, instance.InstanceId, instance.ProjectId, baseUrl);

        var recipientInfo = new RecipientInfo
        {
            Email = email,
            AadObjectId = recipient.AadObjectId,
            SlackUserId = recipient.SlackUserId
        };

        // Resolve display name for email channel (non-critical)
        if (channel == "email")
        {
            try
            {
                recipientInfo.DisplayName = await _userResolver.ResolveDisplayNameAsync(email);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Could not resolve display name for {Email}", email);
            }
        }

        var deliveryContext = new DeliveryContext
        {
            Instance = instance,
            Template = template,
            Recipient = recipientInfo,
            IsReminder = true,
            MagicLinkUrl = magicLinkUrl
        };

        return await provider.DeliverAsync(deliveryContext, ct);
    }

    /// <summary>
    /// Attempts delivery for a previously scheduled (deferred) recipient.
    /// Returns true if delivery succeeded, false if still outside business hours or failed.
    /// </summary>
    public async Task<bool> DeliverScheduledAsync(
        QuestionInstance instance,
        QuestionTemplate template,
        InstanceRecipient recipient,
        CancellationToken ct)
    {
        var channel = recipient.Channel ?? "teams";

        // Business hours check — still outside hours?
        var userKey = recipient.AadObjectId ?? recipient.Email ?? recipient.SlackUserId ?? "";
        if (!await _businessHours.IsWithinBusinessHoursAsync(userKey, channel))
            return false;

        if (!_providers.TryGetValue(channel, out var provider))
        {
            _logger.LogWarning("No provider for channel {Channel} during scheduled delivery", channel);
            return false;
        }

        var baseUrl = GetBaseUrl();
        var email = recipient.SlackUserId ?? recipient.Email ?? recipient.AadObjectId ?? "";

        var recipientInfo = new RecipientInfo
        {
            Email = email,
            AadObjectId = recipient.AadObjectId,
            SlackUserId = recipient.SlackUserId
        };

        // Resolve display name for email channel (non-critical)
        if (channel == "email")
        {
            try
            {
                recipientInfo.DisplayName = await _userResolver.ResolveDisplayNameAsync(email);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Could not resolve display name for {Email}", email);
            }
        }

        var magicLinkUrl = await _magicLinkService.GenerateMagicLinkAsync(
            email, instance.InstanceId, instance.ProjectId, baseUrl);

        var deliveryContext = new DeliveryContext
        {
            Instance = instance,
            Template = template,
            Recipient = recipientInfo,
            MagicLinkUrl = magicLinkUrl
        };

        var result = await provider.DeliverAsync(deliveryContext, ct);
        return result.Success;
    }

    private string GetBaseUrl()
    {
        var host = _config["WEBSITE_HOSTNAME"];
        if (!string.IsNullOrEmpty(host))
            return $"https://{host}";

        return _config["BaseUrl"] ?? "https://localhost:5048";
    }
}
