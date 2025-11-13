## Dependency Injection Configuration

### Core DI Principles

- **Constructor Injection**: Always use constructor injection for dependencies, never use service locator pattern or property injection for required dependencies
- **Interface Abstractions**: Define interfaces for all services in appropriate layer and register implementations in DI container using `AddScoped`, `AddTransient`, or `AddSingleton` lifetimes
- **Explicit Dependencies**: Make dependencies explicit through constructor parameters allowing compiler and tooling to verify dependency satisfaction at compile time

### Lifetime Management

- **Scoped Lifetime**: Use `AddScoped` for services that maintain state per request like `DbContext`, repositories, and request-specific services in web applications
- **Singleton Lifetime**: Use `AddSingleton` for stateless services, configuration objects, and expensive-to-create services that can be safely shared across entire application
- **Transient Lifetime**: Use `AddTransient` for lightweight stateless services and services that should not be shared across different consumers within same scope
- **Lifetime Selection**: Choose lifetimes carefully considering thread safety, state management, and performance implications of creating vs. sharing instances
- **Avoid Singleton Pitfalls**: Never register stateful services or services depending on scoped instances as singletons to prevent memory leaks and shared state issues

### Service Collection Organization

- **Extension Methods**: Organize DI registration into extension methods on `IServiceCollection` grouped by layer or feature for clean `Program.cs` and testability
- **Feature-Based Groups**: Create extension methods like `AddRepositories()`, `AddApplicationServices()`, `AddInfrastructureServices()` for clear organization
- **Separate Registrations**: Keep registration methods in separate files or classes organized by concern making dependencies explicit and modules independently testable
- **Fluent API**: Use fluent API patterns allowing method chaining for readability like `services.AddApplicationServices().AddInfrastructureServices()`

### Configuration Integration

- **Options Pattern**: Use `IConfiguration` with Options pattern for strongly-typed configuration, binding JSON sections to POCO classes and registering with DI container
- **Configuration Validation**: Register `IValidateOptions<T>` implementations validating configuration at startup ensuring required settings are present and valid before application runs
- **Environment-Specific**: Support environment-specific configuration through `appsettings.Development.json` and `appsettings.Production.json` files overriding base configuration
- **Options Snapshot**: Use `IOptionsSnapshot<T>` for configuration that can change at runtime enabling hot-reload of configuration without application restart when appropriate

### Advanced Registration Patterns

- **Factory Pattern**: Use factory delegates when constructing instances requires complex logic beyond simple constructor injection
- **Named Services**: When registering multiple implementations of same interface, use factory methods or keyed services to resolve correct implementation at runtime
- **Batch Registration**: Use reflection and assembly scanning to register multiple implementations of same interface automatically discovering all implementations in assembly
- **Conditional Registration**: Implement conditional registration based on environment or configuration options registering different implementations for different deployment scenarios

### Practical DI Setup Example

```csharp
// Program.cs
var builder = WebApplication.CreateBuilder(args);

// Register services by layer/feature
builder.Services
    .AddApplicationServices()
    .AddInfrastructureServices(builder.Configuration)
    .AddPresentationServices();

var app = builder.Build();
app.Run();

// ServiceCollectionExtensions.cs
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddApplicationServices(
        this IServiceCollection services)
    {
        services.AddMediatR(config =>
            config.RegisterServicesFromAssembly(typeof(IApplicationMarker).Assembly));
        services.AddValidatorsFromAssembly(typeof(IApplicationMarker).Assembly);
        return services;
    }

    public static IServiceCollection AddInfrastructureServices(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.AddDbContext<ApplicationDbContext>(options =>
            options.UseNpgsql(configuration.GetConnectionString("DefaultConnection")));
        
        services.AddScoped(typeof(IRepository<>), typeof(Repository<>));
        services.AddScoped<IUserRepository, UserRepository>();
        services.AddSingleton<IEmailService, EmailService>();
        
        return services;
    }

    public static IServiceCollection AddPresentationServices(
        this IServiceCollection services)
    {
        services.AddControllers();
        services.AddEndpointsApiExplorer();
        services.AddSwaggerGen();
        return services;
    }
}
```

### Testing Considerations

- **Interface Segregation**: Keep service interfaces focused and cohesive making them easier to mock for unit testing
- **Testable Constructors**: Ensure all dependencies are injectable through constructor allowing test doubles to be provided
- **Service Locator Anti-Pattern**: Never use `IServiceProvider` directly in application code for service resolution; rely on DI container for resolution
