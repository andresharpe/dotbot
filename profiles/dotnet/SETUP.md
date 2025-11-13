## Setting Up a New .NET Project with dotbot Profile

This guide walks you through creating a new .NET 9.0 project following the vertical slice architecture pattern.

### Before You Start: Initialize dotbot

**First-time only:**
```bash
# Install dotbot globally (one-time setup)
cd ~
git clone https://github.com/andresharpe/dotbot
cd dotbot
pwsh init.ps1
```

**In your project directory:**
```bash
cd your-project
dotbot init --profile dotnet
```

This installs the .NET profile with:
- Vertical slice architecture standards
- Backend, frontend, and testing guidelines
- Complete workflow templates
- AI agent specifications

Then follow the steps below to create your project structure.

## Prerequisites

- .NET 9.0 SDK installed
- PostgreSQL database available (or Docker)
- Git initialized for the project
- PowerShell 7+ (recommended for Windows)
- IDE: Visual Studio 2022, Rider, or VS Code with C# extensions

## Step 1: Create Solution & Core Projects

### 1a. Create Solution Directory

```bash
mkdir YourProject
cd YourProject
git init
```

### 1b. Create Solution

```bash
dotnet new sln -n YourProject
```

### 1c. Create Core Projects

```bash
# Domain entities and shared core
dotnet new classlib -n YourProject.Core -f net9.0
dotnet sln add YourProject.Core/YourProject.Core.csproj

# Data access and shared queries
dotnet new classlib -n YourProject.Data -f net9.0
dotnet sln add YourProject.Data/YourProject.Data.csproj

# Infrastructure services
dotnet new classlib -n YourProject.Infrastructure -f net9.0
dotnet sln add YourProject.Infrastructure/YourProject.Infrastructure.csproj

# API project with features
dotnet new webapi -n YourProject.Api -f net9.0
dotnet sln add YourProject.Api/YourProject.Api.csproj

# Test project
dotnet new xunit -n YourProject.Tests -f net9.0
dotnet sln add YourProject.Tests/YourProject.Tests.csproj
```

### Result
```
YourProject/
├── YourProject.Core/          # Domain entities, events, exceptions
├── YourProject.Data/          # DbContext, migrations, reusable queries
├── YourProject.Infrastructure/ # External services
├── YourProject.Api/           # Features, controllers, Program.cs
├── YourProject.Tests/         # Unit and integration tests
└── YourProject.sln
```

## Step 2: Update Project Files

### 2a. Update Project Properties

Edit each `.csproj` file to add project configuration standards. Example for `YourProject.Core.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <LangVersion>latest</LangVersion>
  </PropertyGroup>

</Project>
```

For `YourProject.Api.csproj`, also add:

```xml
<PropertyGroup>
  <!-- ...existing properties... -->
  <GenerateDocumentationFile>true</GenerateDocumentationFile>
  <UserSecretsId>YourProject-api-secrets</UserSecretsId>
  <DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
</PropertyGroup>
```

## Step 3: Install NuGet Packages

### 3a. Core Dependencies

```bash
cd YourProject.Core
dotnet add package MediatR --version 12.2.0
dotnet add package MediatR.Contracts --version 2.0.1
```

### 3b. Data Access

```bash
cd ../YourProject.Data
dotnet add package EntityFrameworkCore --version 9.0.0
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 9.0.0
dotnet add package FluentValidation --version 11.9.2
```

### 3c. Infrastructure

```bash
cd ../YourProject.Infrastructure
dotnet add package Serilog --version 3.1.1
dotnet add package Serilog.Sinks.Console --version 5.0.1
dotnet add package Serilog.Sinks.File --version 5.0.0
```

### 3d. API

```bash
cd ../YourProject.Api
dotnet add package Serilog.AspNetCore --version 8.0.1
dotnet add package MediatR --version 12.2.0
dotnet add package FluentValidation --version 11.9.2
dotnet add package EntityFrameworkCore --version 9.0.0
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 9.0.0
```

### 3e. Tests

```bash
cd ../YourProject.Tests
dotnet add package xunit --version 2.6.6
dotnet add package xunit.runner.visualstudio --version 2.5.4
dotnet add package FluentAssertions --version 6.12.0
dotnet add package Microsoft.EntityFrameworkCore.InMemory --version 9.0.0
dotnet add package Moq --version 4.20.70
```

## Step 4: Create Project Structure

### 4a. Create Folders in YourProject.Core

```bash
cd YourProject.Core
mkdir Entities Events Exceptions
```

### 4b. Create Folders in YourProject.Data

```bash
cd ../YourProject.Data
mkdir Configurations Queries Migrations
```

### 4c. Create Folders in YourProject.Api

```bash
cd ../YourProject.Api
mkdir Features Infrastructure
```

### 4d. Create Folders in YourProject.Tests

```bash
cd ../YourProject.Tests
mkdir Fixtures Helpers Unit Integration
```

## Step 5: Core Domain Setup

### 5a. Create Base Entities (YourProject.Core/Entities/EntityBase.cs)

```csharp
namespace YourProject.Core.Entities;

public abstract class EntityBase
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? UpdatedAt { get; set; }
}
```

### 5b. Create Domain Events (YourProject.Core/Events/DomainEvent.cs)

```csharp
namespace YourProject.Core.Events;

public abstract record DomainEvent(Guid Id, DateTime OccurredAt)
{
    public Guid Id { get; } = Id == Guid.Empty ? Guid.NewGuid() : Id;
    public DateTime OccurredAt { get; } = OccurredAt == default ? DateTime.UtcNow : OccurredAt;
}
```

### 5c. Create Domain Exceptions (YourProject.Core/Exceptions/DomainException.cs)

```csharp
namespace YourProject.Core.Exceptions;

public abstract class DomainException : Exception
{
    protected DomainException(string message) : base(message) { }
}
```

## Step 6: Data Access Setup

### 6a. Create DbContext (YourProject.Data/AppDbContext.cs)

```csharp
using Microsoft.EntityFrameworkCore;
using YourProject.Core.Entities;

namespace YourProject.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    // Add DbSets for your entities
    // public DbSet<User> Users { get; set; }
    // public DbSet<Order> Orders { get; set; }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        
        // Apply configurations
        modelBuilder.ApplyConfigurationsFromAssembly(GetType().Assembly);
    }
}
```

### 6b. Create Database Configuration (YourProject.Data/Configurations/README.md)

Add placeholder note:

```markdown
# Entity Configurations

Place IEntityTypeConfiguration implementations here.

Example:
- UserConfiguration.cs
- OrderConfiguration.cs
```

## Step 7: API Setup

### 7a. Update Program.cs (YourProject.Api/Program.cs)

```csharp
using Serilog;
using YourProject.Data;
using Microsoft.EntityFrameworkCore;

var builder = WebApplicationBuilder.CreateBuilder(args);

// Logging
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .WriteTo.Console()
    .WriteTo.File("logs/app-.txt", rollingInterval: RollingInterval.Day)
    .Enrich.FromLogContext()
    .CreateLogger();

builder.Host.UseSerilog();

// Services
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

// Database
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("DefaultConnection")));

// MediatR and Validation
builder.Services.AddMediatR(config =>
    config.RegisterServicesFromAssembly(typeof(Program).Assembly));
builder.Services.AddValidatorsFromAssembly(typeof(Program).Assembly);

// CORS
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowLocal", policy =>
        policy
            .WithOrigins("http://localhost:3000", "http://localhost:5173")
            .AllowAnyMethod()
            .AllowAnyHeader()
            .AllowCredentials());
});

var app = builder.Build();

// Middleware
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseCors("AllowLocal");
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

// Apply migrations
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.Migrate();
}

app.Run();
```

### 7b. Create appsettings.json (YourProject.Api/appsettings.json)

```json
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=localhost;Database=YourProject;Username=postgres;Password=postgres"
  },
  "Serilog": {
    "MinimumLevel": "Information",
    "WriteTo": [
      { "Name": "Console" },
      {
        "Name": "File",
        "Args": {
          "path": "logs/app-.txt",
          "rollingInterval": "Day"
        }
      }
    ]
  }
}
```

### 7c. Create appsettings.Development.json (YourProject.Api/appsettings.Development.json)

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Debug",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "Serilog": {
    "MinimumLevel": "Debug"
  }
}
```

## Step 8: Create First Feature (Example: CreateUser)

### 8a. Create Feature Folder

```bash
cd YourProject.Api/Features
mkdir CreateUser
cd CreateUser
```

### 8b. Create Command (CreateUserCommand.cs)

```csharp
using MediatR;

namespace YourProject.Api.Features.CreateUser;

public class CreateUserCommand : IRequest<CreateUserResponse>
{
    public string Email { get; set; } = null!;
    public string FullName { get; set; } = null!;
}

public record CreateUserResponse(Guid Id, string Email, string FullName);
```

### 8c. Create Validator (CreateUserValidator.cs)

```csharp
using FluentValidation;

namespace YourProject.Api.Features.CreateUser;

public class CreateUserValidator : AbstractValidator<CreateUserCommand>
{
    public CreateUserValidator()
    {
        RuleFor(x => x.Email)
            .NotEmpty().WithMessage("Email is required")
            .EmailAddress().WithMessage("Email must be valid");

        RuleFor(x => x.FullName)
            .NotEmpty().WithMessage("Full name is required")
            .MinimumLength(2).WithMessage("Full name must be at least 2 characters");
    }
}
```

### 8d. Create Handler (CreateUserHandler.cs)

```csharp
using MediatR;
using YourProject.Data;

namespace YourProject.Api.Features.CreateUser;

public class CreateUserHandler : IRequestHandler<CreateUserCommand, CreateUserResponse>
{
    private readonly AppDbContext _context;
    private readonly ILogger<CreateUserHandler> _logger;

    public CreateUserHandler(AppDbContext context, ILogger<CreateUserHandler> logger)
    {
        _context = context;
        _logger = logger;
    }

    public async Task<CreateUserResponse> Handle(
        CreateUserCommand request,
        CancellationToken cancellationToken)
    {
        // TODO: Implement business logic
        // For now, just create a simple response
        var response = new CreateUserResponse(Guid.NewGuid(), request.Email, request.FullName);
        
        _logger.LogInformation("User created: {UserId}", response.Id);
        
        return response;
    }
}
```

### 8e. Create Endpoint (UsersController.cs)

```csharp
using MediatR;
using Microsoft.AspNetCore.Mvc;
using YourProject.Api.Features.CreateUser;

namespace YourProject.Api.Features.CreateUser;

[ApiController]
[Route("api/[controller]")]
public class UsersController : ControllerBase
{
    private readonly IMediator _mediator;

    public UsersController(IMediator mediator) => _mediator = mediator;

    [HttpPost]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> CreateUser(
        [FromBody] CreateUserCommand command,
        CancellationToken cancellationToken)
    {
        var response = await _mediator.Send(command, cancellationToken);
        return CreatedAtAction(nameof(GetUser), new { id = response.Id }, response);
    }

    [HttpGet("{id}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetUser([FromRoute] Guid id)
    {
        // TODO: Implement GetUserByIdQuery
        return Ok(new { id, email = "placeholder@example.com" });
    }
}
```

### 8f. Create Tests (CreateUserTests.cs)

```csharp
using FluentAssertions;
using YourProject.Api.Features.CreateUser;
using Xunit;

namespace YourProject.Tests.Unit.Features.CreateUser;

public class CreateUserTests
{
    [Fact]
    public void Validator_WithValidData_Succeeds()
    {
        // Arrange
        var validator = new CreateUserValidator();
        var command = new CreateUserCommand 
        { 
            Email = "test@example.com", 
            FullName = "Test User" 
        };

        // Act
        var result = validator.Validate(command);

        // Assert
        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validator_WithInvalidEmail_Fails()
    {
        // Arrange
        var validator = new CreateUserValidator();
        var command = new CreateUserCommand 
        { 
            Email = "invalid", 
            FullName = "Test User" 
        };

        // Act
        var result = validator.Validate(command);

        // Assert
        result.IsValid.Should().BeFalse();
        result.Errors.Should().ContainSingle(e => e.PropertyName == "Email");
    }
}
```

## Step 9: Setup Database

### 9a. Create First Migration

```bash
cd YourProject.Api
dotnet ef migrations add InitialCreate --project ../YourProject.Data
```

### 9b. PostgreSQL Setup

Option 1: Local PostgreSQL
```bash
# On Windows with PostgreSQL installed
# Create database
psql -U postgres -c "CREATE DATABASE YourProject;"
```

Option 2: Docker
```bash
docker run --name yourproject-db \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=YourProject \
  -p 5432:5432 \
  -d postgres:16
```

### 9c. Apply Migration

```bash
dotnet ef database update --project YourProject.Data
```

## Step 10: Build & Test

```bash
# Build all projects
dotnet build

# Run tests
dotnet test

# Start API
cd YourProject.Api
dotnet run

# Test endpoint
curl -X POST http://localhost:5000/api/users \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","fullName":"Test User"}'
```

## Step 11: Project Configuration Checklist

- [ ] All .csproj files have `Nullable>enable</Nullable>`
- [ ] All .csproj files have `<ImplicitUsings>enable</ImplicitUsings>`
- [ ] All .csproj files have `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`
- [ ] API project has `<GenerateDocumentationFile>true</GenerateDocumentationFile>`
- [ ] All packages match .NET 9.0 compatibility
- [ ] Database connection string configured in appsettings.json
- [ ] Serilog configured and logging
- [ ] MediatR and validators registered
- [ ] First feature (CreateUser) implemented
- [ ] Tests passing locally

## Step 12: Initialize Git

```bash
git add .
git commit -m "Initial project setup with vertical slice architecture"
```

## Next Steps

1. **Review Standards**: Read `.bot/standards/backend/vertical-slice-architecture.md`
2. **Review Workflow**: Follow `.bot/workflows/implementation/vertical-slice-implementation.md`
3. **Add Features**: Create Features/YourFeature/ folders following the pattern
4. **Extract Queries**: If query used 2+ times, move to Data/Queries/
5. **Add Authentication**: Implement JWT if needed using `.bot/standards/backend/authentication.md`

## Project Layout Final

```
YourProject/
├── YourProject.Core/
│   ├── Entities/
│   │   └── EntityBase.cs
│   ├── Events/
│   │   └── DomainEvent.cs
│   └── Exceptions/
│       └── DomainException.cs
├── YourProject.Data/
│   ├── Configurations/
│   ├── Queries/
│   ├── Migrations/
│   ├── AppDbContext.cs
│   └── YourProject.Data.csproj
├── YourProject.Infrastructure/
│   └── Services/
├── YourProject.Api/
│   ├── Features/
│   │   └── CreateUser/
│   │       ├── CreateUserCommand.cs
│   │       ├── CreateUserValidator.cs
│   │       ├── CreateUserHandler.cs
│   │       ├── CreateUserResponse.cs
│   │       ├── UsersController.cs
│   │       └── CreateUserTests.cs
│   ├── Infrastructure/
│   ├── Program.cs
│   ├── appsettings.json
│   ├── appsettings.Development.json
│   └── YourProject.Api.csproj
├── YourProject.Tests/
│   ├── Fixtures/
│   ├── Helpers/
│   ├── Unit/
│   ├── Integration/
│   └── YourProject.Tests.csproj
└── YourProject.sln
```

## Troubleshooting

**Migration Issues**
```bash
# Reset migrations
dotnet ef migrations remove
dotnet ef migrations add InitialCreate
dotnet ef database update
```

**NuGet Package Conflicts**
```bash
# Clear cache and restore
dotnet nuget locals all --clear
dotnet restore
```

**Port Already in Use**
```bash
# Change port in launchSettings.json or specify in Program.cs
dotnet run --urls "https://localhost:5001"
```

## Using with AI Assistance

When generating features with AI:

1. Provide requirements: "Create a feature to list all users with pagination"
2. Specify folder: "Features/ListUsers/"
3. Ask for complete feature: "Generate all files: Command/Query, Handler, Validator, Response, Endpoint, Tests"
4. Review generated code
5. Run tests immediately: `dotnet test`
6. Fix any issues and regenerate if needed

This setup is optimized for AI-assisted development!
