---
name: integrate-graph-api
description: Integrate with Microsoft Graph API for email, calendar, and organizational data access with proper authentication and error handling
auto_invoke: true
---

# Integrate Microsoft Graph API

Guide for working with Microsoft Graph API to access Microsoft 365 data.

## When to Use

- Accessing user email and messages
- Reading and managing calendar events
- Getting organizational hierarchy and user profiles
- Sending emails on behalf of users

## Authentication Setup

### App Registration
1. Register app in Azure AD
2. Configure API permissions (Mail.Read, Calendars.ReadWrite, User.Read, etc.)
3. Get client ID, tenant ID, and client secret

### Authentication Flow
```csharp
var scopes = new[] { "https://graph.microsoft.com/.default" };
var options = new TokenCredentialOptions
{
    AuthorityHost = AzureAuthorityHosts.AzurePublicCloud
};

var clientSecretCredential = new ClientSecretCredential(
    tenantId, clientId, clientSecret, options);

var graphClient = new GraphServiceClient(clientSecretCredential, scopes);
```

## Common Operations

### Email Operations

**List Messages**
```csharp
var messages = await graphClient.Users[userId]
    .Messages
    .Request()
    .Select("id,subject,from,receivedDateTime,bodyPreview")
    .Filter($"receivedDateTime ge {sinceDate:o}")
    .OrderBy("receivedDateTime desc")
    .Top(50)
    .GetAsync();
```

**Send Email**
```csharp
var message = new Message
{
    Subject = subject,
    Body = new ItemBody
    {
        ContentType = BodyType.Html,
        Content = htmlBody
    },
    ToRecipients = recipients.Select(r => new Recipient
    {
        EmailAddress = new EmailAddress { Address = r }
    }).ToList()
};

await graphClient.Users[userId]
    .SendMail(message, saveToSentItems: true)
    .Request()
    .PostAsync();
```

### Calendar Operations

**Get Calendar Events**
```csharp
var events = await graphClient.Users[userId]
    .CalendarView
    .Request()
    .Header("Prefer", "outlook.timezone=\"UTC\"")
    .Select("id,subject,start,end,attendees,location")
    .Top(100)
    .GetAsync(startDateTime, endDateTime);
```

**Create Calendar Event**
```csharp
var newEvent = new Event
{
    Subject = subject,
    Start = new DateTimeTimeZone
    {
        DateTime = startTime.ToString("o"),
        TimeZone = "UTC"
    },
    End = new DateTimeTimeZone
    {
        DateTime = endTime.ToString("o"),
        TimeZone = "UTC"
    },
    Attendees = attendees.Select(a => new Attendee
    {
        EmailAddress = new EmailAddress { Address = a.Email, Name = a.Name },
        Type = AttendeeType.Required
    }).ToList()
};

await graphClient.Users[userId]
    .Events
    .Request()
    .AddAsync(newEvent);
```

### User Operations

**Get User Profile**
```csharp
var user = await graphClient.Users[userId]
    .Request()
    .Select("displayName,jobTitle,department,officeLocation,manager")
    .Expand("manager")
    .GetAsync();
```

## Error Handling

```csharp
try
{
    var messages = await graphClient.Users[userId].Messages.Request().GetAsync();
}
catch (ServiceException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
{
    // Handle not found
}
catch (ServiceException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Unauthorized)
{
    // Handle auth failure - refresh token
}
catch (ServiceException ex)
{
    // Log and handle other Graph API errors
    _logger.LogError(ex, "Graph API error: {Code} - {Message}", ex.Error.Code, ex.Error.Message);
}
```

## Best Practices

- **Use $select** - Request only needed properties
- **Batch requests** - Use batch API for multiple operations
- **Handle rate limits** - Implement retry logic with exponential backoff
- **Use delta queries** - For incremental sync
- **Cache tokens** - Don't authenticate on every request
- **Use UTC** - Always work in UTC for dates

## Common Pitfalls

- ❌ Not selecting specific properties (over-fetching)
- ❌ Not handling pagination
- ❌ Ignoring rate limit headers
- ❌ Not refreshing expired tokens
- ❌ Using wrong permission scopes
- ❌ Not handling time zones properly

## Checklist

- [ ] App registered with correct permissions
- [ ] Authentication configured and tested
- [ ] Proper error handling for API failures
- [ ] Rate limiting/retry logic implemented
- [ ] Only necessary properties selected
- [ ] Pagination handled for large result sets
- [ ] Timezone handling is correct (use UTC)
- [ ] Tokens refreshed appropriately
