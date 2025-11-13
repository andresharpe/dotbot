## Quick Start: New .NET Project (5 Minutes)

### Prerequisites: dotbot Setup

**Have you initialized dotbot yet?**

If not, first run in your project:
```bash
dotbot init --profile dotnet
```

This installs .NET standards, workflows, and agents. See the main [dotbot README](../../README.md) for details.

**Then continue below:**

---

**See SETUP.md for detailed walkthrough**

## Commands (Copy-Paste)

```bash
# 1. Create project structure
mkdir MyProject
cd MyProject
git init
dotnet new sln -n MyProject

dotnet new classlib -n MyProject.Core -f net9.0
dotnet sln add MyProject.Core/MyProject.Core.csproj

dotnet new classlib -n MyProject.Data -f net9.0
dotnet sln add MyProject.Data/MyProject.Data.csproj

dotnet new classlib -n MyProject.Infrastructure -f net9.0
dotnet sln add MyProject.Infrastructure/MyProject.Infrastructure.csproj

dotnet new webapi -n MyProject.Api -f net9.0
dotnet sln add MyProject.Api/MyProject.Api.csproj

dotnet new xunit -n MyProject.Tests -f net9.0
dotnet sln add MyProject.Tests/MyProject.Tests.csproj

# 2. Install packages
cd MyProject.Core
dotnet add package MediatR --version 12.2.0

cd ../MyProject.Data
dotnet add package EntityFrameworkCore --version 9.0.0
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 9.0.0
dotnet add package FluentValidation --version 11.9.2

cd ../MyProject.Infrastructure
dotnet add package Serilog --version 3.1.1
dotnet add package Serilog.Sinks.Console --version 5.0.1
dotnet add package Serilog.Sinks.File --version 5.0.0

cd ../MyProject.Api
dotnet add package Serilog.AspNetCore --version 8.0.1
dotnet add package MediatR --version 12.2.0
dotnet add package FluentValidation --version 11.9.2
dotnet add package EntityFrameworkCore --version 9.0.0
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 9.0.0

cd ../MyProject.Tests
dotnet add package xunit --version 2.6.6
dotnet add package xunit.runner.visualstudio --version 2.5.4
dotnet add package FluentAssertions --version 6.12.0
dotnet add package Microsoft.EntityFrameworkCore.InMemory --version 9.0.0
dotnet add package Moq --version 4.20.70

# 3. Create folders
cd ../MyProject.Core
mkdir Entities Events Exceptions

cd ../MyProject.Data
mkdir Configurations Queries Migrations

cd ../MyProject.Api
mkdir Features Infrastructure

cd ../MyProject.Tests
mkdir Fixtures Helpers Unit Integration

# 4. Create database
docker run --name myproject-db \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=MyProject \
  -p 5432:5432 \
  -d postgres:16

# 5. Test
dotnet build
dotnet test
cd MyProject.Api
dotnet run
```

## Key Files to Create (Copy from SETUP.md)

### MyProject.Core/Entities/EntityBase.cs
### MyProject.Core/Events/DomainEvent.cs
### MyProject.Core/Exceptions/DomainException.cs
### MyProject.Data/AppDbContext.cs
### MyProject.Api/Program.cs
### MyProject.Api/appsettings.json
### MyProject.Api/appsettings.Development.json

## First Feature: CreateUser

Create folder: `MyProject.Api/Features/CreateUser/`

Files needed (see SETUP.md Step 8):
- CreateUserCommand.cs
- CreateUserValidator.cs
- CreateUserHandler.cs
- UsersController.cs
- CreateUserTests.cs

## Project Config (.csproj Updates)

Add to all `.csproj` PropertyGroup:
```xml
<Nullable>enable</Nullable>
<ImplicitUsings>enable</ImplicitUsings>
<TreatWarningsAsErrors>true</TreatWarningsAsErrors>
```

For API project additionally:
```xml
<GenerateDocumentationFile>true</GenerateDocumentationFile>
<UserSecretsId>MyProject-api-secrets</UserSecretsId>
<DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
```

## Verify Everything

```bash
✓ dotnet build (0 warnings)
✓ dotnet test (all pass)
✓ dotnet run (app starts)
✓ curl http://localhost:5000/api/users (works)
```

## Ready? Start Creating Features

1. Create folder: `Features/YourFeature/`
2. Add: Command, Validator, Handler, Response, Endpoint, Tests
3. Run: `dotnet test` (should pass)
4. Use with AI:
   ```
   Create a complete feature in Features/YourFeature/ including:
   - YourFeatureCommand.cs
   - YourFeatureValidator.cs
   - YourFeatureHandler.cs
   - YourFeatureResponse.cs
   - YourFeatureController.cs
   - YourFeatureTests.cs
   ```

## Resources

- **dotbot Overview**: See `../../README.md` for dotbot basics
- **dotbot Setup**: See main dotbot README for global installation
- **Full Setup**: See `SETUP.md`
- **Architecture**: `.bot/standards/backend/vertical-slice-architecture.md`
- **Workflow**: `.bot/workflows/implementation/vertical-slice-implementation.md`
- **API Guide**: `.bot/standards/backend/api-development.md`
- **Data Access**: `.bot/standards/backend/entity-framework.md`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Port 5000 in use | `dotnet run --urls "https://localhost:5001"` |
| DB won't connect | Check connection string in appsettings.json |
| Migrations error | `dotnet ef migrations remove` then `add InitialCreate` |
| Package conflicts | `dotnet nuget locals all --clear` then `restore` |

---

That's it! You now have a modern .NET 9.0 project optimized for AI-assisted development with vertical slices.

Questions? See the full SETUP.md guide.
