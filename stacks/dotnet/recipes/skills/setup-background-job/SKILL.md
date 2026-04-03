---
name: setup-background-job
description: Set up scheduled background jobs using Quartz.NET with proper configuration, error handling, and dependency injection
auto_invoke: true
---

# Setup Background Job

Guide for creating scheduled background jobs using Quartz.NET.

## When to Use

- Periodic tasks (email polling, data sync, cleanup)
- Scheduled operations (daily reports, reminders)
- Recurring background processing
- Cron-based job scheduling

## Job Implementation

```csharp
public class EmailPollingJob : IJob
{
    private readonly IEmailService _emailService;
    private readonly ILogger<EmailPollingJob> _logger;
    
    public EmailPollingJob(IEmailService emailService, ILogger<EmailPollingJob> logger)
    {
        _emailService = emailService;
        _logger = logger;
    }
    
    public async Task Execute(IJobExecutionContext context)
    {
        _logger.LogInformation("Email polling job started");
        
        try
        {
            await _emailService.PollNewEmails();
            _logger.LogInformation("Email polling completed successfully");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error polling emails");
            throw new JobExecutionException(ex, refireImmediately: false);
        }
    }
}
```

## Job Registration

```csharp
// In Program.cs or Startup.cs
services.AddQuartz(q =>
{
    q.UseMicrosoftDependencyInjectionJobFactory();
    
    // Define the job
    var jobKey = new JobKey("EmailPollingJob");
    q.AddJob<EmailPollingJob>(opts => opts.WithIdentity(jobKey));
    
    // Create a trigger
    q.AddTrigger(opts => opts
        .ForJob(jobKey)
        .WithIdentity("EmailPollingTrigger")
        .WithCronSchedule("0 */5 * * * ?")); // Every 5 minutes
});

services.AddQuartzHostedService(q => q.WaitForJobsToComplete = true);
```

## Cron Expressions

Common patterns:

```
0 0 8 * * ?        - Every day at 8:00 AM
0 */5 * * * ?      - Every 5 minutes
0 30 17 * * ?      - Every day at 5:30 PM
0 0 0 ? * SUN      - Every Sunday at midnight
0 0 * * * ?        - Every hour
0 */30 * * * ?     - Every 30 minutes
0 0 1 1 * ?        - First day of month at 1:00 AM
```

Format: `second minute hour day-of-month month day-of-week`

## Job Data

Pass parameters to jobs:

```csharp
// When scheduling
q.AddTrigger(opts => opts
    .ForJob(jobKey)
    .UsingJobData("userId", "user123")
    .UsingJobData("maxItems", 50)
    .WithCronSchedule("0 0 * * * ?"));

// In job
public async Task Execute(IJobExecutionContext context)
{
    var userId = context.MergedJobDataMap.GetString("userId");
    var maxItems = context.MergedJobDataMap.GetInt("maxItems");
    // ... use parameters
}
```

## Error Handling

```csharp
public async Task Execute(IJobExecutionContext context)
{
    try
    {
        await DoWork();
    }
    catch (TransientException ex)
    {
        // Retry immediately
        throw new JobExecutionException(ex, refireImmediately: true);
    }
    catch (Exception ex)
    {
        // Log and don't retry
        _logger.LogError(ex, "Job failed");
        throw new JobExecutionException(ex, refireImmediately: false);
    }
}
```

## Job Control

### Pause/Resume
```csharp
await scheduler.PauseJob(jobKey);
await scheduler.ResumeJob(jobKey);
```

### Trigger Immediately
```csharp
await scheduler.TriggerJob(jobKey);
```

### Remove Job
```csharp
await scheduler.DeleteJob(jobKey);
```

## Best Practices

- **Dependency Injection** - Use DI for services
- **Idempotent** - Jobs should be safe to run multiple times
- **Logging** - Log start, completion, and errors
- **Timeout** - Consider job execution timeout
- **Overlap** - Prevent concurrent executions if needed
- **Configuration** - Use appsettings for schedules

## Preventing Concurrent Execution

```csharp
[DisallowConcurrentExecution]
public class ExclusiveJob : IJob
{
    // Only one instance runs at a time
}
```

## Job Persistence

For production, use persistent job store:

```csharp
services.AddQuartz(q =>
{
    q.UsePersistentStore(s =>
    {
        s.UseSqlite(sqlite =>
        {
            sqlite.ConnectionString = "Data Source=quartz.db";
        });
        s.UseJsonSerializer();
    });
});
```

## Common Pitfalls

- ❌ Not handling exceptions properly
- ❌ Long-running jobs blocking other jobs
- ❌ Not using DisallowConcurrentExecution when needed
- ❌ Hardcoding schedules instead of configuration
- ❌ Not logging job execution
- ❌ Forgetting to register job with DI

## Checklist

- [ ] Job class implements IJob
- [ ] Dependencies injected via constructor
- [ ] Error handling implemented
- [ ] Logging added (start/complete/error)
- [ ] Job registered with Quartz
- [ ] Trigger configured with correct schedule
- [ ] Cron expression tested
- [ ] DisallowConcurrentExecution if needed
- [ ] Configuration externalized
