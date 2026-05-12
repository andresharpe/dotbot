---
name: entity-design
description: "Design EF Core entities with navigation properties, value objects, Fluent API configuration, and audit fields. Use when creating new database entities, adding relationships, configuring owned types, designing a domain model for Entity Framework Core, or setting up table-per-hierarchy inheritance."
---

# Entity Design (EF Core)

Design and configure EF Core entities following project conventions.

## Workflow

1. **Define the entity class** with properties and base class inheritance
2. **Add navigation properties** for relationships
3. **Create `IEntityTypeConfiguration<T>`** with Fluent API configuration
4. **Register in DbContext** via `OnModelCreating` or assembly scanning
5. **Generate and review migration** to verify the resulting schema

## Entity Structure

```csharp
public class Invoice : EntityBase
{
    public string InvoiceNumber { get; set; } = string.Empty;
    public decimal Total { get; set; }
    public InvoiceStatus Status { get; set; }

    // Navigation properties
    public Guid CustomerId { get; set; }
    public Customer Customer { get; set; } = null!;
    public ICollection<InvoiceLineItem> LineItems { get; set; } = new List<InvoiceLineItem>();
}
```

## Configuration

```csharp
public class InvoiceConfiguration : IEntityTypeConfiguration<Invoice>
{
    public void Configure(EntityTypeBuilder<Invoice> builder)
    {
        builder.HasKey(x => x.Id);
        builder.Property(x => x.InvoiceNumber).HasMaxLength(50).IsRequired();
        builder.Property(x => x.Total).HasPrecision(18, 2);

        builder.HasOne(x => x.Customer)
            .WithMany(c => c.Invoices)
            .HasForeignKey(x => x.CustomerId)
            .OnDelete(DeleteBehavior.Restrict);

        builder.HasMany(x => x.LineItems)
            .WithOne(li => li.Invoice)
            .HasForeignKey(li => li.InvoiceId)
            .OnDelete(DeleteBehavior.Cascade);

        // Concurrency token
        builder.Property<byte[]>("RowVersion").IsRowVersion();
    }
}
```

## Best Practices

- **Fluent API over data annotations** for complex mappings — keeps entities clean
- **Owned types** for value objects (e.g., `Address`, `Money`) — `builder.OwnsOne(x => x.Address)`
- **Shadow properties** for audit fields (`CreatedAt`, `ModifiedAt`) via `SaveChanges` override
- **Explicit cascade delete** — always configure `OnDelete()` to avoid surprise cascades
- **Concurrency tokens** — add `[Timestamp]` or `IsRowVersion()` for entities edited concurrently

## Checklist

- [ ] Entity inherits from project base class (if applicable)
- [ ] Navigation properties defined with correct foreign key
- [ ] `IEntityTypeConfiguration<T>` created with Fluent API
- [ ] Cascade delete behavior configured explicitly
- [ ] Concurrency token added for concurrently-edited entities
- [ ] Value objects use owned types, not separate tables
- [ ] Migration generated and schema verified
