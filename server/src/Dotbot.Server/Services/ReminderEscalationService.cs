using Dotbot.Server.Services.Delivery;

namespace Dotbot.Server.Services;

/// <summary>
/// Background service that periodically checks for unanswered questions
/// and sends reminders or triggers escalation.
/// </summary>
public class ReminderEscalationService : BackgroundService
{
    private readonly IServiceProvider _services;
    private readonly IConfiguration _config;
    private readonly ILogger<ReminderEscalationService> _logger;

    public ReminderEscalationService(
        IServiceProvider services,
        IConfiguration config,
        ILogger<ReminderEscalationService> logger)
    {
        _services = services;
        _config = config;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var intervalMinutes = _config.GetValue("Reminders:IntervalMinutes", 60);
        _logger.LogInformation("ReminderEscalationService started, interval: {Interval} minutes", intervalMinutes);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ProcessCycleAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error in reminder/escalation cycle");
            }

            await Task.Delay(TimeSpan.FromMinutes(intervalMinutes), stoppingToken);
        }
    }

    private async Task ProcessCycleAsync(CancellationToken ct)
    {
        using var scope = _services.CreateScope();
        var instanceStorage = scope.ServiceProvider.GetRequiredService<InstanceStorageService>();
        var templateStorage = scope.ServiceProvider.GetRequiredService<ITemplateStorageService>();
        var responseStorage = scope.ServiceProvider.GetRequiredService<ResponseStorageService>();
        var orchestrator = scope.ServiceProvider.GetRequiredService<DeliveryOrchestrator>();

        var defaultReminderHours = _config.GetValue("Reminders:DefaultReminderAfterHours", 24);
        var defaultEscalateDays = _config.GetValue("Reminders:DefaultEscalateAfterDays", 3);
        var now = DateTime.UtcNow;
        var processed = 0;

        await foreach (var instance in instanceStorage.ListActiveInstancesAsync().WithCancellation(ct))
        {
            var template = await templateStorage.GetTemplateAsync(
                instance.ProjectId, instance.QuestionId, instance.QuestionVersion);
            if (template is null)
                continue;

            var reminderHours = instance.DeliveryOverrides?.ReminderAfterHours
                ?? template.DeliveryDefaults?.ReminderAfterHours
                ?? defaultReminderHours;
            var escalateDays = instance.DeliveryOverrides?.EscalateAfterDays
                ?? template.DeliveryDefaults?.EscalateAfterDays
                ?? defaultEscalateDays;

            var instanceModified = false;

            foreach (var recipient in instance.SentTo)
            {
                // ── Handle scheduled (deferred) recipients ──────────────────
                if (recipient.Status == "scheduled")
                {
                    // Escalation safety net: if past escalation threshold from instance creation, escalate anyway
                    if (recipient.EscalatedAt is null &&
                        now > instance.CreatedAt.AddDays(escalateDays))
                    {
                        recipient.EscalatedAt = now;
                        recipient.Status = "escalated";
                        instanceModified = true;
                        _logger.LogWarning(
                            "Escalated scheduled recipient {Recipient} for instance {InstanceId} — past {Days}-day threshold",
                            recipient.Email ?? recipient.AadObjectId, instance.InstanceId, escalateDays);
                        continue;
                    }

                    // Attempt deferred delivery
                    try
                    {
                        var delivered = await orchestrator.DeliverScheduledAsync(instance, template, recipient, ct);
                        if (delivered)
                        {
                            recipient.Status = "sent";
                            recipient.SentAt = now;
                            instanceModified = true;
                            _logger.LogInformation(
                                "Delivered scheduled message to {Recipient} for instance {InstanceId}",
                                recipient.Email ?? recipient.AadObjectId, instance.InstanceId);
                        }
                        // else: still outside business hours, leave as "scheduled" for next cycle
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Failed scheduled delivery to {Recipient}",
                            recipient.Email ?? recipient.AadObjectId);
                    }
                    continue;
                }

                // ── Existing reminder/escalation logic ──────────────────────
                if (recipient.Status is not ("sent" or "reminded"))
                    continue;
                if (recipient.SentAt is null)
                    continue;

                // Check if a response already exists
                var hasResponse = false;
                await foreach (var response in responseStorage.ListResponsesAsync(
                    instance.ProjectId, instance.QuestionId, instance.InstanceId))
                {
                    // Match on AAD object ID (exact), email (case-insensitive), or Slack user ID.
                    // Slack magic links are issued with the Slack user ID as the email claim,
                    // so ResponderEmail will equal the SlackUserId for Slack responses.
                    bool match =
                        (!string.IsNullOrEmpty(response.ResponderAadObjectId) &&
                         !string.IsNullOrEmpty(recipient.AadObjectId) &&
                         response.ResponderAadObjectId == recipient.AadObjectId)
                        ||
                        (!string.IsNullOrEmpty(response.ResponderEmail) &&
                         !string.IsNullOrEmpty(recipient.Email) &&
                         string.Equals(response.ResponderEmail, recipient.Email, StringComparison.OrdinalIgnoreCase))
                        ||
                        (!string.IsNullOrEmpty(response.ResponderEmail) &&
                         !string.IsNullOrEmpty(recipient.SlackUserId) &&
                         string.Equals(response.ResponderEmail, recipient.SlackUserId, StringComparison.OrdinalIgnoreCase));

                    if (match)
                    {
                        hasResponse = true;
                        break;
                    }
                }

                if (hasResponse)
                    continue;

                // Check for reminder — defer if outside business hours
                if (recipient.LastReminderAt is null &&
                    now > recipient.SentAt.Value.AddHours(reminderHours))
                {
                    try
                    {
                        var result = await orchestrator.DeliverReminderAsync(instance, template, recipient, ct);
                        if (result.Channel == "outside_business_hours")
                        {
                            // Don't mark as reminded — retry next cycle
                            _logger.LogDebug("Deferred reminder for {Recipient} — outside business hours",
                                recipient.Email ?? recipient.AadObjectId);
                        }
                        else if (result.Success)
                        {
                            recipient.LastReminderAt = now;
                            recipient.Status = "reminded";
                            instanceModified = true;
                            _logger.LogInformation(
                                "Sent reminder to {Recipient} for instance {InstanceId}",
                                recipient.Email ?? recipient.AadObjectId, instance.InstanceId);
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Failed to send reminder to {Recipient}", recipient.Email ?? recipient.AadObjectId);
                    }
                }

                // Check for escalation
                if (recipient.EscalatedAt is null &&
                    now > recipient.SentAt.Value.AddDays(escalateDays))
                {
                    recipient.EscalatedAt = now;
                    recipient.Status = "escalated";
                    instanceModified = true;
                    _logger.LogWarning(
                        "Escalated: {Recipient} has not responded to instance {InstanceId} after {Days} days",
                        recipient.Email ?? recipient.AadObjectId, instance.InstanceId, escalateDays);
                }
            }

            // Update overall status if all recipients are escalated or failed (skip empty sentTo)
            if (instance.SentTo.Count > 0 && instance.SentTo.All(r => r.Status is "escalated" or "failed"))
            {
                instance.OverallStatus = "escalated";
                instanceModified = true;
            }

            if (instanceModified)
            {
                await instanceStorage.SaveInstanceAsync(instance);
                processed++;
            }
        }

        if (processed > 0)
            _logger.LogInformation("Reminder/escalation cycle updated {Count} instances", processed);
    }
}
