## Vertical Slice Architecture

Vertical slice architecture organizes features as complete, self-contained slices where each feature includes all layers (command/query, handler, validation, response, endpoint, tests) in one cohesive folder.

### Overview

Rather than organizing by technical layers (Domain, Application, Infrastructure), organize by business feature:

```
Features/
├── CreateUser/
│   ├── CreateUserCommand.cs
│   ├── CreateUserHandler.cs
│   ├── CreateUserValidator.cs
│   ├── CreateUserResponse.cs
│   ├── CreateUserEndpoint.cs
│   └── CreateUserTests.cs
├── UpdateUserProfile/
│   ├── UpdateUserProfileCommand.cs
│   ├── UpdateUserProfileHandler.cs
│   ├── UpdateUserProfileValidator.cs
│   ├── UpdateUserProfileResponse.cs
│   ├── UpdateUserProfileEndpoint.cs
│   └── UpdateUserProfileTests.cs
└── SearchUsers/
    ├── SearchUsersQuery.cs
    ├── SearchUsersHandler.cs
    ├── SearchUsersValidator.cs
    ├── SearchUsersResponse.cs
    ├── SearchUsersEndpoint.cs
    └── SearchUsersTests.cs

Core/                          # Shared domain logic
├── Entities/
│   ├── User.cs
│   └── Order.cs
├── Events/
│   └── DomainEvent.cs
└── Exceptions/
    └── DomainException.cs

Data/                          # Shared data access
├── AppDbContext.cs
├── Queries/                   # Reusable queries across features
│   ├── GetUserByIdQuery.cs
│   ├── GetUserByEmailQuery.cs
│   └── ListActiveUsersQuery.cs
└── Migrations/

Infrastructure/
├── Services/                  # External integrations (email, payments, etc)
└── Configuration/
```

### Key Principles

- **Feature Cohesion**: All code for a feature lives in one folder
- **Minimal Cross-Feature Dependencies**: Features are largely independent
- **Shared Core**: Domain entities and events in Core/ folder
- **Reusable Queries**: Extract queries appearing in multiple features to Data/Queries/
- **Direct DbContext**: Use DbContext directly in handlers; it IS your repository
- **Simple DI**: Register handlers and validators by feature; minimal configuration

### Feature Folder Structure

Each feature folder contains:

#### Command/Query Class
```csharp
// Features/CreateUser/CreateUserCommand.cs
public class CreateUserCommand : IRequest<CreateUserResponse>
{
    public string Email { get; set; } = null!;
    public string FullName { get; set; } = null!;
}

// Features/SearchUsers/SearchUsersQuery.cs
public class SearchUsersQuery : IRequest<SearchUsersResponse>
{
    public string? SearchTerm { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 10;
}
```

#### Handler Class
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
        // Check business rule: unique email
        var existingUser = await _context.Users
            .FirstOrDefaultAsync(u => u.Email == request.Email, cancellationToken);
        
        if (existingUser != null)
            throw new DuplicateEmailException(request.Email);

        // Create entity with business logic
        var user = new User(request.Email, request.FullName);
        
        _context.Users.Add(user);
        await _context.SaveChangesAsync(cancellationToken);

        _logger.LogInformation("User created: {UserId}", user.Id);

        return new CreateUserResponse(user.Id, user.Email, user.FullName);
    }
}
```

#### Validator Class
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
            .NotEmpty().WithMessage("Full name is required")
            .MinimumLength(2).WithMessage("Full name must be at least 2 characters");
    }
}
```

#### Response DTO
```csharp
// Features/CreateUser/CreateUserResponse.cs
public record CreateUserResponse(Guid Id, string Email, string FullName);
```

#### Endpoint
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

#### Tests
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
        var command = new CreateUserCommand { Email = "test@example.com", FullName = "Test User" };

        // Act
        var result = await handler.Handle(command, CancellationToken.None);

        // Assert
        result.Email.Should().Be("test@example.com");
        context.Users.Should().ContainSingle();
    }

    [Fact]
    public async Task Handle_WithDuplicateEmail_ThrowsException()
    {
        // Arrange
        var context = new InMemoryDbContextFactory().Create();
        context.Users.Add(new User("existing@example.com", "Existing User"));
        await context.SaveChangesAsync();

        var handler = new CreateUserHandler(context, new NullLogger<CreateUserHandler>());
        var command = new CreateUserCommand { Email = "existing@example.com", FullName = "New User" };

        // Act & Assert
        await handler.Invoking(h => h.Handle(command, CancellationToken.None))
            .Should()
            .ThrowAsync<DuplicateEmailException>();
    }
}
```

### Shared Queries (Data/Queries/)

Extract queries that appear across multiple features:

```csharp
// Data/Queries/GetUserByIdQuery.cs
public class GetUserByIdQuery : IRequest<UserDto?>
{
    public Guid UserId { get; set; }
}

public class GetUserByIdQueryHandler : IRequestHandler<GetUserByIdQuery, UserDto?>
{
    private readonly AppDbContext _context;

    public GetUserByIdQueryHandler(AppDbContext context) => _context = context;

    public async Task<UserDto?> Handle(GetUserByIdQuery request, CancellationToken cancellationToken)
    {
        return await _context.Users
            .AsNoTracking()
            .Where(u => u.Id == request.UserId)
            .Select(u => new UserDto(u.Id, u.Email, u.FullName))
            .FirstOrDefaultAsync(cancellationToken);
    }
}
```

### Advantages of Vertical Slices

#### For AI-Assisted Development
- **Complete context** - AI sees entire feature in one place
- **Self-contained generation** - AI can generate complete feature without juggling files
- **Fewer coordination points** - Less chance of AI missing dependencies
- **Easier review** - PR contains complete feature, not scattered changes

#### For Developers
- **Feature clarity** - Know where all code for a feature lives
- **Minimal navigation** - No jumping between Domain/Application/Infrastructure
- **Easy to extract** - Move feature folder if needed
- **Testing focus** - Tests live next to implementation
- **Less ceremony** - No mapper classes, no separate layer files

#### For Teams
- **Parallel development** - Teams work independently on features
- **Reduced conflicts** - Each feature has its own folder
- **Clear ownership** - Feature folder = one team's responsibility
- **Scalability** - Add features by adding folders

### Limitations to Watch

- **Code duplication**: Queries appearing in multiple features should be extracted to Data/Queries/
- **Cross-feature dependencies**: Keep minimal; if features depend heavily, reconsider boundaries
- **Shared business logic**: Extract to Core/Entities or create shared utilities
- **Testing complexity**: Avoid testing integration across features; test each feature in isolation

### When to Use Vertical Slices

✅ **Use when:**
- Building with AI assistance and speed matters
- Team is small to medium-sized (< 20 developers)
- Features are relatively independent
- Project timeline is important
- Starting with uncertain requirements

❌ **Avoid if:**
- Extensive code reuse needed across features
- Complex business logic shared across many features
- Large team needs strict architectural boundaries
- Enterprise requires layered architecture for compliance
- High risk of architectural drift matters more than speed

### Migrating to Vertical Slices

If starting with clean architecture:

1. Group Domain/Application/Infrastructure code by feature
2. Move related command, handler, validator together
3. Extract shared queries to Data/Queries/
4. Consolidate tests into feature folder
5. Update DI registration to be feature-based

### Example: Complete Feature

```
Features/CreateUser/
├── CreateUserCommand.cs          # Request model
├── CreateUserHandler.cs          # Command handler
├── CreateUserValidator.cs        # Validation rules
├── CreateUserResponse.cs         # Response DTO
├── CreateUserEndpoint.cs         # Controller method
└── CreateUserTests.cs            # All tests for feature

// After extracting reusable part:
Data/Queries/
├── GetUserByIdQuery.cs
├── GetUserByIdQueryHandler.cs
└── GetUserByIdQueryValidator.cs
```

This keeps features self-contained while avoiding duplication.
