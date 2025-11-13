## Vertical Slice Implementation Workflow

**Agent:** `.bot/agents/backend-developer.md`

**Interaction Standard:** Follow `.bot/standards/global/workflow-interaction.md`

This workflow guides you through implementing features using vertical slices - complete, self-contained feature folders ideal for AI-assisted development.

## Prerequisites

- Feature requirements clearly defined
- Database entities designed (if new entities needed)
- API endpoint decided (path, HTTP method)
- Development environment set up with .NET 9.0 and PostgreSQL

## Steps

### 1. Create Feature Folder

Create a new folder under Features/:

```
Features/CreateUser/
```

This single folder will contain the complete feature.

### 2. Design Command/Query Class

Define the request model for your feature:

```csharp
// Features/CreateUser/CreateUserCommand.cs
public class CreateUserCommand : IRequest<CreateUserResponse>
{
    public string Email { get; set; } = null!;
    public string FullName { get; set; } = null!;
}
```

**Guidelines:**
- Use record or class (class for mutability during binding)
- Inherit from `IRequest<TResponse>` for MediatR
- Include only data needed for the operation
- Use nullable reference types (`= null!` for required fields)

### 3. Create Validator

Add validation rules in the same folder:

```csharp
// Features/CreateUser/CreateUserValidator.cs
public class CreateUserValidator : AbstractValidator<CreateUserCommand>
{
    public CreateUserValidator()
    {
        RuleFor(x => x.Email)
            .NotEmpty().WithMessage("Email is required")
            .EmailAddress().WithMessage("Email must be valid");

        RuleFor(x => x.FullName)
            .NotEmpty().WithMessage("Full name is required");
    }
}
```

**Guidelines:**
- Define all validation rules here
- Use FluentValidation fluent API
- Clear error messages for API consumers
- Don't duplicate backend validation on client

### 4. Implement Handler

Create the handler that executes the business logic:

```csharp
// Features/CreateUser/CreateUserHandler.cs
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
        // Business rule validation
        var existingUser = await _context.Users
            .FirstOrDefaultAsync(u => u.Email == request.Email, cancellationToken);
        
        if (existingUser != null)
            throw new DuplicateEmailException(request.Email);

        // Create domain entity
        var user = new User(request.Email, request.FullName);
        
        // Use DbContext directly (no repository abstraction)
        _context.Users.Add(user);
        await _context.SaveChangesAsync(cancellationToken);

        _logger.LogInformation("User created: {UserId}", user.Id);

        return new CreateUserResponse(user.Id, user.Email, user.FullName);
    }
}
```

**Guidelines:**
- Inject `AppDbContext` directly (DbContext is your repository)
- Validate business rules before database operations
- Use DbContext LINQ queries directly
- Log important operations with context
- Return response DTO from handler

### 5. Define Response DTO

Create the response model:

```csharp
// Features/CreateUser/CreateUserResponse.cs
public record CreateUserResponse(Guid Id, string Email, string FullName);
```

**Guidelines:**
- Use record for simple DTOs (immutable, concise)
- Include only data needed by client
- Separate from domain entities
- Public, serializable properties

### 6. Create API Endpoint

Add the controller action:

```csharp
// Features/CreateUser/CreateUserEndpoint.cs
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
    public async Task<IActionResult> GetUser(
        [FromRoute] Guid id,
        CancellationToken cancellationToken)
    {
        var query = new GetUserByIdQuery(id);
        var result = await _mediator.Send(query, cancellationToken);
        
        if (result == null)
            return NotFound();

        return Ok(result);
    }
}
```

**Guidelines:**
- Keep controller actions minimal
- Inject IMediator to send commands/queries
- Delegate logic to handlers
- Return appropriate HTTP status codes
- Add [ProducesResponseType] for documentation

### 7. Write Comprehensive Tests

Add tests in the feature folder:

```csharp
// Features/CreateUser/CreateUserTests.cs
public class CreateUserTests
{
    [Fact]
    public async Task Handle_WithValidData_CreatesUser()
    {
        // Arrange
        var context = new InMemoryDbContextFactory().Create();
        var handler = new CreateUserHandler(context, new NullLogger<CreateUserHandler>());
        var command = new CreateUserCommand 
        { 
            Email = "test@example.com", 
            FullName = "Test User" 
        };

        // Act
        var result = await handler.Handle(command, CancellationToken.None);

        // Assert
        result.Id.Should().NotBeEmpty();
        result.Email.Should().Be("test@example.com");
        context.Users.Should().ContainSingle();
    }

    [Fact]
    public async Task Handle_WithDuplicateEmail_ThrowsException()
    {
        // Arrange
        var context = new InMemoryDbContextFactory().Create();
        context.Users.Add(new User("existing@example.com", "Existing"));
        await context.SaveChangesAsync();

        var handler = new CreateUserHandler(context, new NullLogger<CreateUserHandler>());
        var command = new CreateUserCommand 
        { 
            Email = "existing@example.com", 
            FullName = "New User" 
        };

        // Act & Assert
        await handler.Invoking(h => h.Handle(command, CancellationToken.None))
            .Should()
            .ThrowAsync<DuplicateEmailException>();
    }

    [Fact]
    public void Validate_WithInvalidEmail_Fails()
    {
        // Arrange
        var validator = new CreateUserValidator();
        var command = new CreateUserCommand { Email = "invalid", FullName = "User" };

        // Act
        var result = validator.Validate(command);

        // Assert
        result.IsValid.Should().BeFalse();
        result.Errors.Should().ContainSingle(e => e.PropertyName == "Email");
    }
}
```

**Guidelines:**
- Test happy path first
- Test business rule violations
- Test validation rules
- Use in-memory database
- Use NullLogger for tests
- Keep tests focused and readable

### 8. Register in Dependency Injection

Update Program.cs to register handlers:

```csharp
// Program.cs
builder.Services.AddMediatR(config =>
    config.RegisterServicesFromAssembly(typeof(Program).Assembly));

builder.Services.AddValidatorsFromAssembly(typeof(Program).Assembly);
```

**Note:** Validator registration uses assembly scanning - validators are automatically discovered.

### 9. Configure Database (if needed)

Update DbContext if adding new entities:

```csharp
// Data/AppDbContext.cs
public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }
    
    public DbSet<User> Users { get; set; }
    
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        
        modelBuilder.Entity<User>(e =>
        {
            e.HasKey(u => u.Id);
            e.Property(u => u.Email).IsRequired().HasMaxLength(255);
            e.HasIndex(u => u.Email).IsUnique();
        });
    }
}
```

### 10. Create/Run Migration

If you added new entities:

```bash
dotnet ef migrations add AddUsers
dotnet ef database update
```

### 11. Test Everything

Run tests to verify the feature works:

```bash
dotnet test
```

Run the application and test the endpoint:

```bash
dotnet run
# POST http://localhost:5000/api/users
# {
#   "email": "test@example.com",
#   "fullName": "Test User"
# }
```

### 12. Extract Reusable Queries (if applicable)

If your query (like GetUserById) is used in multiple features, extract it:

```
Data/Queries/
├── GetUserByIdQuery.cs
├── GetUserByIdQueryHandler.cs
└── GetUserByIdQueryValidator.cs
```

**When to extract:**
- Query appears in 2+ handlers
- Query is complex or reused
- Want to centralize optimization

### 13. Code Review Checklist

Before completing:
- [ ] Feature folder is self-contained
- [ ] Command/Query is clear and complete
- [ ] Validator covers all rules
- [ ] Handler implements business logic correctly
- [ ] Database queries optimized (AsNoTracking, projections)
- [ ] Error handling for business rule violations
- [ ] Tests cover happy path and error cases
- [ ] Tests pass locally
- [ ] No hardcoded values
- [ ] No sensitive data logged
- [ ] Code is readable and follows conventions

## Best Practices

### Keep Features Independent
- Each feature folder should be self-contained
- Minimal dependencies between features
- Share only Core entities and Data queries

### Direct DbContext Usage
- Don't create repository abstractions "just in case"
- Use DbContext directly in handlers
- DbContext IS a repository + Unit of Work
- Extract queries only if reused 2+ times

### Optimize Queries
- Use `AsNoTracking()` for read-only queries
- Use `Select()` to project only needed columns
- Use `Include()` for eager loading relationships
- Avoid N+1 query problems

### Error Handling
- Throw domain exceptions for business rule violations
- Return appropriate HTTP status codes
- Log errors with full context
- Provide helpful error messages to API consumers

### Testing Strategy
- Test handlers with in-memory database
- Test validators independently
- Test happy path first
- Test business rule violations
- Keep tests focused and maintainable

## Complete Feature Example

```
Features/CreateUser/
├── CreateUserCommand.cs          # Request model (10 lines)
├── CreateUserValidator.cs        # Validation (15 lines)
├── CreateUserHandler.cs          # Business logic (30 lines)
├── CreateUserResponse.cs         # Response DTO (3 lines)
├── CreateUserEndpoint.cs         # API endpoint (20 lines)
└── CreateUserTests.cs            # Tests (50 lines)

Total: ~130 lines per feature, all in one folder
```

## Output

For each feature:
- ✓ Complete, self-contained feature folder
- ✓ Command/Query with validation
- ✓ Handler with business logic
- ✓ API endpoint
- ✓ Tests covering happy and error paths
- ✓ Database migrations (if needed)
- ✓ Ready for immediate use

## Common Pitfalls

❌ **Spreading feature across multiple files**
✓ Keep feature in single folder

❌ **Creating repository abstractions prematurely**
✓ Use DbContext directly until proven necessary

❌ **Mixing queries across features without extraction**
✓ Extract only when query appears in 2+ features

❌ **Skipping tests**
✓ Tests are critical for rapid iteration confidence

❌ **Not handling business rule violations**
✓ Throw custom exceptions for violations
✓ Test exception scenarios

## Tips for AI-Assisted Development

This pattern works exceptionally well with AI assistance:

1. **Complete context** - AI sees entire feature in one conversation
2. **Self-contained generation** - AI can generate complete, working features
3. **Easier review** - PR contains complete feature, not scattered changes
4. **Minimal coordination** - Less chance of AI missing cross-file dependencies
5. **Rapid iteration** - Generate feature, test, refine, done

When using AI to generate features:
- Provide clear requirements (what should it do?)
- Specify the feature name (determines folder name)
- Ask for complete feature (all files together)
- Test immediately to verify correctness
- Ask AI to fix failing tests
