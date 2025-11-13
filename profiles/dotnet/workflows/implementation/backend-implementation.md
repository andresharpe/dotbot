## Backend Implementation Workflow

**Agent:** `.bot/agents/backend-developer.md`

**Interaction Standard:** When asking questions or gathering clarifications, follow `.bot/standards/global/workflow-interaction.md`

This workflow guides you through implementing backend features using clean architecture, CQRS, and Entity Framework Core.

## Prerequisites

- Completed specification document
- Database schema designed
- API contracts defined
- Development environment configured with .NET 9.0
- PostgreSQL database available

## Steps

### 1. Design Domain Model

Before writing any code, design the core domain:

- Review specification and identify domain concepts (entities, value objects)
- Define domain entities with invariants and business rules
- Create value objects for domain concepts without identity
- Identify domain events that need to be published
- **Reference Standard**: `.bot/standards/backend/clean-architecture.md`

### 2. Set Up Project Structure

Organize projects following clean architecture:

```
YourFeature/
├── YourFeature.Contracts/       # DTOs, API models
├── YourFeature.Domain/          # Business logic, entities
├── YourFeature.Application/     # Commands, queries, services
├── YourFeature.Infrastructure/  # EF Core, repositories
└── YourFeature.Tests/           # Unit and integration tests
```

- Create projects with proper references
- Configure .NET project settings (nullable, implicit usings, warnings as errors)
- **Reference Standard**: `.bot/standards/global/project-configuration.md`

### 3. Implement Domain Layer

Create pure domain logic independent of infrastructure:

- Define entities with proper encapsulation and business logic
- Create value objects for domain concepts
- Add domain events for significant business occurrences
- **Don't** add database code, external dependencies, or DTOs here
- **Reference Standard**: `.bot/standards/backend/clean-architecture.md`

### 4. Define DTOs & Contracts

Create request/response models in Contracts layer:

- Define request DTOs for API endpoints
- Create response DTOs separating API contracts from domain entities
- Include validation attributes where appropriate
- Ensure DTOs are serializable and have sensible defaults
- **Reference Standard**: `.bot/standards/backend/cqrs-mediatr.md`

### 5. Implement Application Commands & Queries

Create CQRS handlers in Application layer:

**For Write Operations (Commands):**
- Create command class inheriting from `IRequest<TResponse>`
- Implement command handler with business logic
- Handle domain events and side effects
- Return command result (ID of created resource, etc.)

**For Read Operations (Queries):**
- Create query class inheriting from `IRequest<TResponse>`
- Implement query handler with optimized database queries
- Use projections to return only needed data
- Never modify state in query handlers

**Reference Standards**:
- `.bot/standards/backend/cqrs-mediatr.md` - Command/Query structure
- `.bot/standards/backend/dependency-injection.md` - Handler registration

### 6. Create Validators

Add FluentValidation validators in Application layer:

- Create validator class inheriting from `AbstractValidator<T>`
- Define validation rules using fluent API
- Use `WithMessage` for clear error messages
- Support async validators for database checks
- Register validators with `AddValidatorsFromAssembly`
- **Reference Standard**: `.bot/standards/backend/cqrs-mediatr.md`

### 7. Implement Repository Pattern

Create data access abstraction in Infrastructure layer:

- Define repository interfaces in Domain layer
- Implement repositories wrapping `DbContext`
- Create generic `IRepository<T>` for common operations
- Add specialized repositories for complex queries
- Use `AsNoTracking` for read-only queries
- **Reference Standard**: `.bot/standards/backend/entity-framework.md`

### 8. Configure Entity Framework

Set up database access:

- Create `DbContext` with entity configurations
- Implement `IEntityTypeConfiguration<T>` for each entity
- Use Fluent API for complex mappings (not data annotations)
- Create and apply migrations: `dotnet ef migrations add`
- **Reference Standard**: `.bot/standards/backend/entity-framework.md`

### 9. Create API Endpoints

Expose functionality through ASP.NET Core controllers:

- Create controller inheriting from `ControllerBase`
- Use `[ApiController]` and route attributes
- Inject `IMediator` for command/query execution
- Return appropriate `ActionResult` types with status codes
- Add `[ProducesResponseType]` attributes for documentation
- **Reference Standard**: `.bot/standards/backend/api-development.md`

### 10. Implement Security

Add authentication and authorization:

- Configure JWT authentication in `Program.cs`
- Apply `[Authorize]` attributes to protected endpoints
- Use claims-based authorization for fine-grained access control
- Inject `ICurrentUserService` to access user context
- **Reference Standard**: `.bot/standards/backend/authentication.md`

### 11. Add Logging

Implement structured logging with Serilog:

- Configure Serilog in `Program.cs`
- Inject `ILogger<T>` into handlers and services
- Log important operations and errors
- Include correlation IDs for tracing
- **Never** log sensitive data
- **Reference Standard**: `.bot/standards/backend/logging.md`

### 12. Implement Error Handling

Create proper error handling:

- Define custom domain exceptions
- Create global exception handling middleware
- Return appropriate HTTP status codes
- Return structured error responses
- Log errors with full context for debugging
- **Reference Standard**: `.bot/standards/global/error-handling.md`

### 13. Write Tests

Create unit and integration tests:

- Write unit tests for command/query handlers
- Test repository queries for correctness
- Test validators with various inputs
- Mock external dependencies for unit tests
- Use real database for integration tests
- Keep tests focused on business logic
- **Reference Standard**: `.bot/standards/global/test-writing.md`

### 14. Performance Optimization

Optimize queries and performance:

- Use query projections with `Select`
- Implement eager loading with `Include/ThenInclude`
- Add database indexes on filtered columns
- Monitor query performance
- Implement caching where appropriate
- **Reference Standard**: `.bot/standards/backend/entity-framework.md`

### 15. Code Review

Self-review before completing:

- Verify clean architecture principles followed
- Check CQRS separation (commands vs queries)
- Ensure proper dependency injection
- Validate error handling coverage
- Review security controls
- Check logging and observability
- Verify tests are passing
- **Reference Standard**: `.bot/agents/backend-developer.md` (Code Review Checklist)

## Best Practices

### CQRS Pattern
- **Separate concerns**: Commands handle writes, queries handle reads
- **Independent optimization**: Optimize reads and writes separately
- **Event-driven**: Emit domain events for significant changes

### Error Handling
- **Validate inputs**: Validate all requests in pipeline behavior
- **Custom exceptions**: Use domain exceptions for business rule violations
- **Graceful failures**: Handle expected errors with appropriate responses
- **Log failures**: Log all errors with full context

### Testing Strategy
- **Focus on logic**: Test business logic in handlers, not repositories
- **Happy path**: Always cover main flow first
- **Error cases**: Test validation and error handling
- **Integration**: Test database interactions separately

### Performance
- **Optimize queries**: Use projections, eager loading, indexes
- **Caching**: Implement caching for frequently accessed data
- **Async all the way**: Use async/await for scalability
- **Monitor metrics**: Track performance and identify bottlenecks

## Output

For each feature:
- ✓ Clean domain entities and value objects
- ✓ Commands and queries implementing use cases
- ✓ FluentValidation validators
- ✓ Repository implementations with optimized queries
- ✓ EF Core configurations and migrations
- ✓ API endpoints with proper responses
- ✓ Authentication and authorization
- ✓ Structured logging with Serilog
- ✓ Comprehensive error handling
- ✓ Unit and integration tests
- ✓ Documentation and comments
- ✓ Code passing review checklist

## Common Pitfalls

❌ **Mixing concerns across layers**
✓ Keep domain pure, infrastructure separate, application orchestrating

❌ **Over-complicating for CQRS**
✓ Use CQRS only when benefits justify complexity

❌ **N+1 query problems**
✓ Always use eager loading or projections for queries

❌ **Missing validation in pipeline**
✓ Always validate in MediatR pipeline behavior before handler

❌ **Hardcoded configuration**
✓ Always use `IConfiguration` for settings

❌ **Not logging failures**
✓ Log all errors with full context for production debugging

❌ **Skipping tests**
✓ Tests are critical for maintainability and refactoring confidence
