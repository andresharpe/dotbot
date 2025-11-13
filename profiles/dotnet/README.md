## .NET Profile for dotbot

This profile provides comprehensive coding standards, architectural guidance, and development workflows for .NET projects using vertical slice architecture.

### Getting Started with dotbot

**New to dotbot?** First read the main dotbot README:
1. Install dotbot globally: `pwsh ~/dotbot/init.ps1`
2. Initialize in your project: `dotbot init --profile dotnet`
3. This installs all .NET standards, workflows, and agents

See `SETUP.md` for complete .NET project setup or `QUICK_START.md` for the fast version.

### Overview

The .NET profile is designed for teams building scalable, maintainable applications with:

- **Clean Architecture** - Strict layer separation with proper dependency rules
- **CQRS Pattern** - Separated command (write) and query (read) operations using MediatR
- **Modern .NET** - .NET 9.0 with nullable reference types and implicit usings
- **Entity Framework Core** - PostgreSQL-first data access with advanced patterns
- **ASP.NET Core APIs** - RESTful API design with comprehensive security
- **Blazor WebAssembly** - Full-stack C# development with MudBlazor components

### Architectural Approaches

#### Vertical Slice Architecture (Recommended for Most Projects)

Best for: AI-assisted development, rapid iteration, small-to-medium teams

```
Features/
├── CreateUser/             # Feature folder (complete & self-contained)
│   ├── CreateUserCommand.cs
│   ├── CreateUserHandler.cs
│   ├── CreateUserValidator.cs
│   ├── CreateUserResponse.cs
│   ├── CreateUserEndpoint.cs
│   └── CreateUserTests.cs
├── UpdateProfile/
└── SearchUsers/

Core/                        # Shared domain entities & events
├── Entities/
└── Events/

Data/                        # Shared data access
├── AppDbContext.cs
├── Queries/                # Reusable queries extracted from features
└── Migrations/

Infrastructure/             # External services & config
└── Services/
```

Advantages:
- Complete context for AI-assisted code generation
- Self-contained features with minimal dependencies
- Easy parallel team development
- Reduced merge conflicts
- Clear feature ownership
- Rapid iteration and feature delivery

Workflow: See `.bot/workflows/implementation/vertical-slice-implementation.md`

#### Clean Architecture (For Complex Domains)

Best for: Complex business logic, large teams, enterprise requirements

```
Domain/                     # Pure business logic
├── Entities/
└── Events/

Application/                # Use cases & orchestration
├── Commands/
├── Queries/
└── Services/

Infrastructure/             # External concerns
├── Data/
└── Services/

Contracts/                  # DTOs & public API

Presentation/               # Controllers, Blazor
```

Advantages:
- Strict separation of concerns
- Highly testable architecture
- Framework-independent business logic
- Enterprise compliance & governance
- Clear layer boundaries

When to use:
- Complex domain model with extensive business rules
- Large teams (20+ developers)
- Long-lived project with high change frequency
- Enterprise requirements mandate layered architecture

### Directory Structure

```
profiles/dotnet/
├── standards/              # Coding standards and best practices
│   ├── global/            # Language-agnostic standards
│   ├── backend/
│   │   ├── vertical-slice-architecture.md    # PRIMARY: Vertical slices
│   │   ├── clean-architecture.md             # ALTERNATIVE: Clean architecture
│   │   ├── cqrs-mediatr.md                   # Shared pattern
│   │   ├── entity-framework.md               # DbContext-as-repository
│   │   ├── dependency-injection.md           # DI configuration
│   │   ├── api-development.md                # REST conventions
│   │   ├── authentication.md                 # Security
│   │   └── logging.md                        # Observability
│   └── frontend/          # Frontend standards
├── agents/                # AI agent personalities
│   ├── backend-developer.md
│   ├── frontend-developer.md
│   └── solution-architect.md
├── workflows/             # Development workflows
│   ├── implementation/
│   │   ├── vertical-slice-implementation.md  # PRIMARY workflow
│   │   └── backend-implementation.md         # ALTERNATIVE workflow
│   ├── specification/
│   └── planning/
└── README.md
```

### Standards

#### Backend Architecture (Choose One)

Vertical Slice Architecture (Recommended)
- `.bot/standards/backend/vertical-slice-architecture.md` - Feature-based organization
- Self-contained feature folders with all layers
- DbContext used directly in handlers
- Ideal for AI-assisted development
- Extract reusable queries to Data/Queries/ only when needed

Clean Architecture (When Needed)
- `.bot/standards/backend/clean-architecture.md` - Layer-based organization
- Strict layer separation and dependency rules
- For complex domains or large teams

#### Shared Backend Standards

- CQRS & MediatR - Command/query separation patterns
- Dependency Injection - Service registration and lifetime management
- Entity Framework Core - PostgreSQL access, migrations, query optimization
- DbContext Usage - Direct context injection; repository abstraction only when justified
- API Development - REST conventions, versioning, error handling
- Authentication - JWT tokens, claims-based authorization, CORS
- Logging - Serilog structured logging with context

#### Frontend Standards

- Blazor WebAssembly - Component architecture, code-behind patterns
- MudBlazor - Exclusive Material Design components
- State Management - Scoped services with event notifications
- HTTP Integration - Typed HttpClient with error handling
- Forms & Validation - EditForm with FluentValidation integration

#### Global Standards

- Project Configuration - .NET 9.0 settings, nullable types, compiler warnings
- Coding Style - Naming conventions, formatting, DRY principle
- Error Handling - Exception handling, validation, recovery
- Conventions - Version control, documentation, dependency management
- Workflow Interaction - User interaction patterns

### Agents

#### Backend Developer
Expert in implementing server-side functionality following clean architecture, CQRS patterns, and enterprise .NET best practices. Guides backend feature development through domain modeling, data access, API creation, and testing.

#### Frontend Developer
Specialist in creating rich, interactive Blazor WebAssembly user interfaces using MudBlazor components. Handles component development, state management, API integration, and accessibility.

#### Solution Architect
Designs scalable, maintainable solutions considering technology selection, project organization, performance, security, and deployment strategies. Provides architectural guidance and design review.

### Workflows

#### Backend Implementation
Step-by-step guide for implementing backend features:

1. Design domain model
2. Set up project structure
3. Implement domain layer
4. Define DTOs & contracts
5. Implement commands & queries
6. Create validators
7. Implement repository pattern
8. Configure Entity Framework
9. Create API endpoints
10. Implement security
11. Add logging
12. Implement error handling
13. Write tests
14. Performance optimization
15. Code review

### Key Technologies

- **Framework**: .NET 9.0
- **Database**: PostgreSQL with Npgsql
- **ORM**: Entity Framework Core
- **API Framework**: ASP.NET Core
- **API Patterns**: MediatR (CQRS), FluentValidation
- **Frontend**: Blazor WebAssembly, MudBlazor
- **Logging**: Serilog
- **Testing**: xUnit, FluentAssertions
- **Dependency Injection**: Microsoft.Extensions.DependencyInjection

### Getting Started

Quick Start (AI-Assisted Development)

1. Choose Vertical Slices - This is optimized for AI assistance
2. Review the workflow: `.bot/workflows/implementation/vertical-slice-implementation.md`
3. Follow feature folder pattern:
   ```
   Features/YourFeature/
   ├── YourFeatureCommand.cs
   ├── YourFeatureHandler.cs
   ├── YourFeatureValidator.cs
   ├── YourFeatureResponse.cs
   ├── YourFeatureEndpoint.cs
   └── YourFeatureTests.cs
   ```
4. Use DbContext directly - No repository abstraction needed
5. Extract reusable queries to `Data/Queries/` when used in 2+ features

Standard Setup

1. Select this profile in dotbot configuration
2. Decide architecture approach:
   - Vertical Slices (default): `.bot/standards/backend/vertical-slice-architecture.md`
   - Clean Architecture (if needed): `.bot/standards/backend/clean-architecture.md`
3. Follow relevant workflow:
   - Vertical Slices: `.bot/workflows/implementation/vertical-slice-implementation.md`
   - Clean Architecture: `.bot/workflows/implementation/backend-implementation.md`
4. Review role-specific standards:
   - Backend developer: Architecture + data access + API standards
   - Frontend developer: Frontend standards + Blazor patterns
   - Architect: All standards + decision matrix
5. Reference standards as needed during development

### Architecture Principles

Pragmatism Over Dogma

Key insight: Most projects benefit from vertical slices. Use clean architecture when:
- Domain complexity genuinely requires it
- Team size warrants strict boundaries
- Enterprise policy mandates it
- Long-term maintainability is the priority

Vertical Slice Architecture
- Organization: By feature/business capability
- Each feature: Completely self-contained with all layers
- DbContext: Used directly; no repository abstraction
- Queries: Extracted to Data/Queries/ when reused
- Advantage: Perfect for AI-assisted development

Clean Architecture (When Needed)
- Domain Layer: Pure business logic, no infrastructure dependencies
- Application Layer: Use cases, commands, queries, services
- Infrastructure Layer: Database, external services, configurations
- Presentation Layers: Controllers, Blazor components
- Contracts Layer: DTOs, API models, shared contracts

SOLID Design Principles
- Single Responsibility: Each class has one reason to change
- Open/Closed: Open for extension, closed for modification
- Liskov Substitution: Derived types substitute for base types
- Interface Segregation: Depend on interfaces you use
- Dependency Inversion: Depend on abstractions, not concretions

### Common Patterns

#### Domain-Driven Design
- Entities with unique identity
- Value objects for immutable concepts
- Aggregates with clear boundaries
- Domain events for significant business occurrences

#### CQRS (Command Query Responsibility Segregation)
- Commands handle write operations (create, update, delete)
- Queries handle read operations (retrieval without side effects)
- Separate optimization for reads vs. writes
- Event-driven communication between commands and queries

#### API Design
- RESTful endpoints with clear resource paths
- Proper HTTP method usage (GET, POST, PUT, DELETE)
- Semantic HTTP status codes
- Comprehensive error responses
- API versioning support

### Best Practices

#### Code Quality
- Use intention-revealing names
- Keep methods small and focused
- Follow DRY (Don't Repeat Yourself) principle
- Maintain consistent formatting
- Add comments for "why" not "what"

#### Data Access
- Use DbContext directly in handlers; it IS your repository
- Don't create repository abstractions unless genuinely needed
- Use projections with `Select()` to return only needed data
- Implement eager loading with `Include()` to avoid N+1 queries
- Add database indexes on frequently filtered columns
- Use `AsNoTracking()` for read-only queries
- Extract queries appearing in 2+ features to `Data/Queries/`
- Implement proper transaction boundaries when needed

#### Security
- Always require authentication for non-public endpoints
- Use claims-based authorization
- Validate all user input
- Never log sensitive data
- Use HTTPS exclusively in production

#### Testing
- Test business logic in domain/handlers
- Mock external dependencies
- Use real database for integration tests
- Cover critical paths
- Keep tests focused and maintainable

### Project Structure Template - Vertical Slices (Recommended)

```
YourProject.sln
├── Features/
│   ├── CreateUser/
│   │   ├── CreateUserCommand.cs
│   │   ├── CreateUserHandler.cs
│   │   ├── CreateUserValidator.cs
│   │   ├── CreateUserResponse.cs
│   │   ├── CreateUserEndpoint.cs
│   │   └── CreateUserTests.cs
│   ├── UpdateProfile/
│   └── SearchUsers/
├── Core/                           # Shared domain entities & events
│   ├── Entities/
│   └── Events/
├── Data/                           # Shared data access
│   ├── AppDbContext.cs
│   ├── Queries/                   # Reusable queries
│   └── Migrations/
├── Infrastructure/                # External services
│   └── Services/
├── Program.cs
└── Tests/                         # Shared test utilities
```

### Project Structure Template - Clean Architecture (If Needed)

```
YourProject.sln
├── YourProject.Contracts/           # DTOs, API models
├── YourProject.Domain/              # Business logic, entities
├── YourProject.Application/         # Commands, queries, services
├── YourProject.Infrastructure/      # EF Core, external services
├── YourProject.Shared/              # Utilities, extensions
├── YourProject.Api/                 # ASP.NET Core API
├── YourProject.BlazorWeb/           # Blazor WebAssembly frontend
└── YourProject.Tests/               # Unit, integration, E2E tests
```

### Configuration

Configure this profile in `config.yml`:

```yaml
profile: dotnet
standards_as_warp_rules: true
```

### Resources

Quick References
- Vertical Slice Workflow (START HERE): `.bot/workflows/implementation/vertical-slice-implementation.md`
- Vertical Slice Architecture: `.bot/standards/backend/vertical-slice-architecture.md`
- DbContext Usage Guide: `.bot/standards/backend/entity-framework.md` - Direct context without repository

Detailed Guides
- Clean Architecture Workflow: `.bot/workflows/implementation/backend-implementation.md` - For complex domains
- Clean Architecture Guide: `.bot/standards/backend/clean-architecture.md` - Layer organization
- CQRS & MediatR: `.bot/standards/backend/cqrs-mediatr.md` - Command/query patterns
- API Standards: `.bot/standards/backend/api-development.md` - REST conventions
- Authentication: `.bot/standards/backend/authentication.md` - Security patterns
- Logging: `.bot/standards/backend/logging.md` - Observability with Serilog

Advanced Topics
- Dependency Injection: `.bot/standards/backend/dependency-injection.md` - Service registration
- Project Configuration: `.bot/standards/global/project-configuration.md` - .NET 9.0 setup

### Support

For questions or clarifications:
1. Review relevant standard documents
2. Check agent guidance for your role
3. Follow the appropriate workflow
4. Reference working code examples
5. Consult architecture principles

### License

Same license as dotbot project.
