## Logging with Serilog

### Serilog Setup & Configuration

- **Serilog as Logger**: Use Serilog as the primary logging framework throughout application replacing default Microsoft logging with structured logging capabilities for better observability
- **Configuration**: Configure Serilog in `Program.cs` during application startup specifying sinks, minimum log level, and enrichers
- **Configuration Files**: Define Serilog configuration in `appsettings.json` with environment-specific overrides in `appsettings.Development.json` and `appsettings.Production.json`
- **Dynamic Levels**: Support changing log levels at runtime through environment variables or configuration allowing adjustment without redeployment

### Sink Configuration

- **Console Sink**: Configure console sink for local development providing immediate feedback during debugging and development
- **File Sink**: Configure file sink with rolling file appender storing logs persistently with rotation by date or file size preventing unbounded disk growth
- **Structured Serilog**: Use structured serilog format outputting JSON in production enabling log aggregation and analysis in centralized log systems
- **Multiple Sinks**: Configure multiple sinks simultaneously directing logs to console, file, and external services simultaneously for redundant logging

### Structured Logging

- **Structured Properties**: Use structured logging with property enrichers logging contextual information as structured data properties rather than string interpolation
- **Contextual Data**: Include relevant context like request IDs, user IDs, operation names as structured properties automatically enriching all logs within scope
- **Property Naming**: Use consistent naming conventions for common properties (UserId, RequestId, CorrelationId) across entire application
- **Performance Impact**: Use structured logging parameters avoiding expensive object serialization by using `LogContext` for scoped properties

### Log Levels

- **Verbose**: Use Verbose level for extremely detailed diagnostic information rarely needed except during deep troubleshooting of specific issues
- **Debug**: Use Debug level for diagnostic information useful during development and debugging including entry/exit of methods and variable values
- **Information**: Use Information level for general flow information like application startup, configuration loaded, significant operations completed
- **Warning**: Use Warning level for concerning but handled situations like deprecated API usage, recoverable errors, retry attempts
- **Error**: Use Error level for errors that don't stop application like failed request, validation errors, transient failures
- **Fatal**: Use Fatal level for catastrophic errors preventing application from continuing like startup failures or unrecoverable system errors

### Request Logging

- **Request Logging Middleware**: Enable Serilog request logging middleware in ASP.NET Core to automatically log HTTP requests and responses with timing information
- **Request Details**: Log request method, path, query string, status code, response time for all API requests providing request/response tracing
- **Request Correlation**: Automatically include correlation IDs in request logs enabling tracing of related requests across distributed system
- **Sensitive Data**: Redact sensitive information from logs (passwords, tokens, PII) preventing accidental exposure in log files

### Exception Logging

- **Exception Information**: Log exceptions with full stack traces, inner exceptions, and contextual properties using logger.Error or logger.Fatal methods
- **Exception Context**: Include relevant context when logging exceptions like user ID, operation name, input parameters aiding troubleshooting
- **Exception Details**: Log exception type, message, and stack trace with inner exception chains for complete error investigation
- **Error Tracking**: Use structured exception properties enabling filtering and aggregation of exception types and patterns

### Logging Configuration Example

```json
// appsettings.json
{
  "Serilog": {
    "MinimumLevel": "Information",
    "WriteTo": [
      {
        "Name": "Console",
        "Args": {
          "theme": "Serilog.Sinks.SystemConsole.Themes.AnsiConsoleTheme::Code, Serilog.Sinks.Console",
          "outputTemplate": "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] {Message:lj}{NewLine}{Exception}"
        }
      },
      {
        "Name": "File",
        "Args": {
          "path": "logs/log-.txt",
          "rollingInterval": "Day",
          "outputTemplate": "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj}{NewLine}{Exception}"
        }
      }
    ],
    "Enrich": ["FromLogContext", "WithMachineName", "WithThreadId"],
    "Properties": {
      "Application": "MyApplication"
    }
  }
}

// appsettings.Production.json
{
  "Serilog": {
    "MinimumLevel": "Warning",
    "WriteTo": [
      {
        "Name": "File",
        "Args": {
          "path": "/var/log/myapp/log-.json",
          "formatter": "Serilog.Formatting.Json.JsonFormatter",
          "rollingInterval": "Day"
        }
      }
    ]
  }
}

// Program.cs
Log.Logger = new LoggerConfiguration()
    .ReadFrom.Configuration(builder.Configuration)
    .CreateLogger();

builder.Host.UseSerilog();

try
{
    Log.Information("Starting application");
    // Build and run application
}
catch (Exception ex)
{
    Log.Fatal(ex, "Application terminated unexpectedly");
}
finally
{
    Log.CloseAndFlush();
}

// Usage in application
public class UserService
{
    private readonly ILogger<UserService> _logger;
    
    public UserService(ILogger<UserService> logger)
    {
        _logger = logger;
    }
    
    public async Task CreateUserAsync(CreateUserCommand command)
    {
        try
        {
            _logger.LogInformation("Creating user: {@Command}", command);
            
            using (LogContext.PushProperty("UserId", userId))
            using (LogContext.PushProperty("Email", command.Email))
            {
                var user = new User { Email = command.Email };
                await _repository.AddAsync(user);
                
                _logger.LogInformation("User created successfully with ID {UserId}", user.Id);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error creating user: {@Command}", command);
            throw;
        }
    }
}
```

### Best Practices

- **Lazy Evaluation**: Use structured logging parameters allowing Serilog to decide whether to serialize objects based on log level
- **No String Interpolation**: Avoid string interpolation in log messages; use structured properties instead for better queryability
- **Correlation IDs**: Use correlation IDs to track requests through system enabling tracing of complete request flow
- **Performance Monitoring**: Log performance metrics like execution times, database query times for performance analysis and optimization
- **Sensitive Data Protection**: Never log passwords, API keys, personal information, or other sensitive data
