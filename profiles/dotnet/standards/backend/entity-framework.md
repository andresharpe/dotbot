## Data Access with Entity Framework Core

### Database Provider & Setup

- **PostgreSQL Provider**: Use Npgsql Entity Framework Core PostgreSQL provider for all database operations with PostgreSQL-specific features like JSONB columns and array types
- **Connection Strings**: Store connection strings in `appsettings.json` for environments and `appsettings.Development.json` using user secrets for sensitive local development data
- **DbContext Registration**: Configure DbContext with connection strings from configuration, registering with DI using `AddDbContext` extension method with scoped lifetime

### Entity Configuration

- **Entity Type Configuration**: Implement `IEntityTypeConfiguration<T>` interface for each entity to define table mappings, relationships, indexes, and constraints in separate configuration classes
- **Fluent API**: Use Entity Framework Core Fluent API in configuration classes rather than data annotations for complex mappings keeping entities clean
- **Separation of Concerns**: Keep configurations separate from entities in dedicated configuration files organized by domain area
- **Convention Over Configuration**: Use consistent naming conventions allowing Entity Framework Core to infer many mappings automatically reducing configuration verbosity

### Practical Entity Configuration

```csharp
// Domain/Entities/User.cs
public class User
{
    public Guid Id { get; set; }
    public string Email { get; set; } = null!;
    public string FullName { get; set; } = null!;
    public DateTime CreatedAt { get; set; }
    
    public ICollection<Order> Orders { get; set; } = new List<Order>();
}

// Infrastructure/Configurations/UserConfiguration.cs
public class UserConfiguration : IEntityTypeConfiguration<User>
{
    public void Configure(EntityTypeBuilder<User> builder)
    {
        builder.HasKey(u => u.Id);
        
        builder.Property(u => u.Email)
            .IsRequired()
            .HasMaxLength(255);
        
        builder.HasIndex(u => u.Email)
            .IsUnique();
        
        builder.HasMany(u => u.Orders)
            .WithOne(o => o.User)
            .HasForeignKey(o => o.UserId);
    }
}

// Infrastructure/Data/ApplicationDbContext.cs
public class ApplicationDbContext : DbContext
{
    public ApplicationDbContext(DbContextOptions<ApplicationDbContext> options)
        : base(options)
    {
    }
    
    public DbSet<User> Users { get; set; }
    public DbSet<Order> Orders { get; set; }
    
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        
        modelBuilder.ApplyConfiguration(new UserConfiguration());
        modelBuilder.ApplyConfiguration(new OrderConfiguration());
        modelBuilder.ApplyConfigurationsFromAssembly(GetType().Assembly);
    }
}
```

### Migrations

- **Code-First Approach**: Use code-first migrations with `dotnet ef` commands for schema evolution, generating migration files that are version controlled alongside application code
- **Migration Naming**: Name migrations descriptively indicating what schema changes they contain like `AddUserTable`, `AddOrderIndexes`, `RenameColumnEmail`
- **Automatic Application**: Apply migrations at application startup in production-safe way checking for pending migrations and applying only necessary migrations
- **Rollback Strategy**: Keep migration files immutable; for schema corrections create new forward migration rather than modifying existing migrations

### Query Optimization

- **AsNoTracking**: Use `AsNoTracking()` for read-only queries to improve performance by skipping change tracking, reserving tracking only for entities being modified
- **Projection**: Use `Select` to project only needed columns from database reducing payload transferred and improving query performance
- **Eager Loading**: Use `Include` and `ThenInclude` for eager loading related entities when needed to avoid N+1 query problems and reduce database roundtrips
- **Lazy Loading**: Avoid lazy loading in APIs; always specify needed relationships explicitly through eager loading preventing unexpected N+1 queries in production

### Query Examples

```csharp
// Good: Projection with AsNoTracking
var userEmails = await context.Users
    .AsNoTracking()
    .Where(u => u.IsActive)
    .Select(u => new { u.Id, u.Email })
    .ToListAsync();

// Good: Eager loading for related data
var user = await context.Users
    .Include(u => u.Orders)
    .ThenInclude(o => o.OrderItems)
    .FirstOrDefaultAsync(u => u.Id == userId);

// Bad: N+1 query problem
var users = await context.Users.ToListAsync();
foreach (var user in users)
{
    var orders = await context.Orders
        .Where(o => o.UserId == user.Id)
        .ToListAsync(); // This fires query for each user!
}
```

### DbContext as Repository

**DbContext IS Your Repository** - Use DbContext directly in handlers; it already abstracts data access:

- **No extra abstraction layer** - DbContext implements Unit of Work and repository patterns already
- **Direct LINQ in handlers** - Write queries directly in handler methods using DbContext
- **Testable without mocks** - Use InMemory EF Core provider for unit tests without repository mocks
- **Simpler code** - Fewer files, less indirection, more readable

```csharp
// Instead of IUserRepository abstraction, use DbContext directly
public class CreateUserHandler : IRequestHandler<CreateUserCommand, UserResponse>
{
    private readonly AppDbContext _context;

    public async Task<UserResponse> Handle(CreateUserCommand request, CancellationToken ct)
    {
        // Direct DbContext query
        var existing = await _context.Users
            .FirstOrDefaultAsync(u => u.Email == request.Email, ct);
        
        if (existing != null)
            throw new DuplicateEmailException();

        var user = new User(request.Email, request.FullName);
        _context.Users.Add(user);  // DbContext tracks changes
        await _context.SaveChangesAsync(ct);
        
        return new UserResponse(user.Id, user.Email);
    }
}
```

### When to Extract Repository Abstraction

**Avoid premature abstraction**, but extract `IRepository<T>` or specialized repository if:

- Query appears in 5+ handlers (extract to Data/Queries/ instead)
- You genuinely need to swap database implementations (rare)
- Enterprise policy requires repository pattern
- You have high complexity warranting abstraction

**Most projects never need this abstraction.** DbContext is sufficient.

### Shared Query Objects

For queries used across multiple features, extract to `Data/Queries/`:

```csharp
// Data/Queries/GetUserByIdQuery.cs - Reusable across features
public class GetUserByIdQuery : IRequest<UserDto?>
{
    public Guid UserId { get; set; }
}

public class GetUserByIdQueryHandler : IRequestHandler<GetUserByIdQuery, UserDto?>
{
    private readonly AppDbContext _context;

    public async Task<UserDto?> Handle(GetUserByIdQuery request, CancellationToken ct)
    {
        return await _context.Users
            .AsNoTracking()
            .Where(u => u.Id == request.UserId)
            .Select(u => new UserDto(u.Id, u.Email, u.FullName))
            .FirstOrDefaultAsync(ct);
    }
}
```

### Transaction Support

DbContext handles transactions automatically via SaveChangesAsync(). For explicit control:

```csharp
await using var transaction = await _context.Database.BeginTransactionAsync(ct);
try
{
    // Multiple operations
    _context.Users.Add(user);
    await _context.SaveChangesAsync(ct);
    
    _context.Orders.Add(order);
    await _context.SaveChangesAsync(ct);
    
    await transaction.CommitAsync(ct);
}
catch
{
    await transaction.RollbackAsync(ct);
    throw;
}
```

### Transaction Management

- **Explicit Transactions**: Handle transactions explicitly using database transactions when multiple operations must succeed or fail together as atomic unit of work
- **Transaction Scope**: Keep transaction scope as narrow as possible minimizing lock contention and improving concurrency
- **Savepoints**: Use savepoints for complex scenarios allowing rollback to intermediate points within transaction if needed
- **Deadlock Handling**: Implement retry logic with exponential backoff for deadlock scenarios allowing automatic recovery from transient locking issues

```csharp
// Transaction example
await using var transaction = await context.Database.BeginTransactionAsync();
try
{
    var user = new User { Email = email };
    context.Users.Add(user);
    await context.SaveChangesAsync();
    
    var order = new Order { UserId = user.Id };
    context.Orders.Add(order);
    await context.SaveChangesAsync();
    
    await transaction.CommitAsync();
}
catch
{
    await transaction.RollbackAsync();
    throw;
}
```

### Performance Best Practices

- **Batch Operations**: Use `AddRange`/`UpdateRange`/`RemoveRange` for bulk operations reducing round-trips to database
- **Bulk Inserts**: Consider bulk insert extensions for high-volume inserts when performance critical
- **Indexes**: Add database indexes on frequently filtered or sorted columns improving query performance
- **Query Limits**: Always limit result sets using `Take` or pagination preventing accidentally fetching entire tables
