---
name: create-migration
description: Create and manage database migrations with Entity Framework Core, including schema changes, data seeding, and rollback strategies
auto_invoke: true
---

# Create Database Migration

Guide for creating and managing database migrations with Entity Framework Core.

## When to Use

- Adding new tables or entities
- Modifying existing schema (columns, indexes, constraints)
- Data migrations or seeding
- Renaming or removing tables/columns

## Migration Workflow

### 1. Update Entity Model
```csharp
public class User
{
    public int Id { get; set; }
    public string Email { get; set; } // New property
    public DateTime CreatedAt { get; set; }
}
```

### 2. Update DbContext
```csharp
public class AppDbContext : DbContext
{
    public DbSet<User> Users { get; set; }
    
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<User>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Email).IsRequired().HasMaxLength(255);
            entity.HasIndex(e => e.Email).IsUnique();
        });
    }
}
```

### 3. Create Migration
```bash
dotnet ef migrations add AddEmailToUser
```

### 4. Review Generated Migration
Check `Up()` and `Down()` methods for correctness.

### 5. Apply Migration
```bash
dotnet ef database update
```

## Migration Best Practices

### Naming Conventions
- Use descriptive, action-oriented names
- Good: `AddEmailColumnToUsers`, `CreateOrdersTable`, `AddIndexOnUserEmail`
- Bad: `Migration1`, `Update`, `Changes`

### Schema Changes

**Adding Columns**
```csharp
migrationBuilder.AddColumn<string>(
    name: "Email",
    table: "Users",
    type: "nvarchar(255)",
    maxLength: 255,
    nullable: false,
    defaultValue: "");
```

**Modifying Columns**
```csharp
migrationBuilder.AlterColumn<string>(
    name: "Name",
    table: "Users",
    type: "nvarchar(100)",
    maxLength: 100,
    nullable: false,
    oldClrType: typeof(string),
    oldType: "nvarchar(50)",
    oldMaxLength: 50);
```

**Adding Indexes**
```csharp
migrationBuilder.CreateIndex(
    name: "IX_Users_Email",
    table: "Users",
    column: "Email",
    unique: true);
```

**Adding Foreign Keys**
```csharp
migrationBuilder.AddForeignKey(
    name: "FK_Orders_Users_UserId",
    table: "Orders",
    column: "UserId",
    principalTable: "Users",
    principalColumn: "Id",
    onDelete: ReferentialAction.Cascade);
```

### Data Migrations

When you need to migrate data alongside schema changes:

```csharp
protected override void Up(MigrationBuilder migrationBuilder)
{
    // 1. Schema change
    migrationBuilder.AddColumn<string>(
        name: "FullName",
        table: "Users",
        nullable: true);
    
    // 2. Data migration
    migrationBuilder.Sql(@"
        UPDATE Users 
        SET FullName = FirstName + ' ' + LastName
        WHERE FirstName IS NOT NULL AND LastName IS NOT NULL
    ");
    
    // 3. Make column required after data is populated
    migrationBuilder.AlterColumn<string>(
        name: "FullName",
        table: "Users",
        nullable: false);
}
```

### Seeding Data

Use model builder for static reference data:

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    modelBuilder.Entity<Role>().HasData(
        new Role { Id = 1, Name = "Admin" },
        new Role { Id = 2, Name = "User" }
    );
}
```

## Rollback Strategy

Always implement proper `Down()` methods:

```csharp
protected override void Down(MigrationBuilder migrationBuilder)
{
    // Reverse the changes made in Up()
    migrationBuilder.DropColumn(
        name: "Email",
        table: "Users");
}
```

## Common Scenarios

### Renaming Columns
```csharp
migrationBuilder.RenameColumn(
    name: "OldName",
    table: "Users",
    newName: "NewName");
```

### Dropping Tables
```csharp
migrationBuilder.DropTable(
    name: "ObsoleteTable");
```

### Adding Composite Keys
```csharp
modelBuilder.Entity<UserRole>()
    .HasKey(ur => new { ur.UserId, ur.RoleId });
```

## SQLite-Specific Considerations

- Limited ALTER TABLE support
- No DROP COLUMN (requires table recreation)
- No ADD CONSTRAINT for foreign keys (must recreate table)
- Use EF Core migration auto-generation, it handles these limitations

## Testing Migrations

1. **Apply migration to fresh database** - Verify Up() works
2. **Roll back migration** - Verify Down() works
3. **Apply on database with data** - Verify no data loss
4. **Test constraints and indexes** - Verify they work as expected

## Common Pitfalls

- ❌ Not testing Down() method
- ❌ Breaking changes without data migration
- ❌ Making nullable→required without default values
- ❌ Forgetting to update seed data
- ❌ Not handling existing data when adding constraints
- ❌ Committing migrations without testing

## Checklist

- [ ] Entity model updated
- [ ] DbContext configuration updated
- [ ] Migration generated with descriptive name
- [ ] Up() method reviewed and correct
- [ ] Down() method implements proper rollback
- [ ] Data migration included if needed
- [ ] Tested on local database
- [ ] Tested rollback
- [ ] No data loss with existing data
