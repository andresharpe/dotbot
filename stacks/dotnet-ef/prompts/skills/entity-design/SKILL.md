---
name: Entity Design (EF Core)
description: EF Core-specific entity design with navigation properties, value objects, and configuration
version: 1.0
---

# Entity Design (EF Core)

## When to Use
- Designing new entities for an EF Core DbContext
- Adding navigation properties and relationships
- Configuring value objects, owned types, or table-per-hierarchy

## Guidelines
- Use Fluent API configuration over data annotations for complex mappings
- Define relationships explicitly in `IEntityTypeConfiguration<T>` classes
- Prefer owned types for value objects (e.g., `Address`, `Money`)
- Use shadow properties for audit fields (`CreatedAt`, `ModifiedAt`) via `SaveChanges` override
- Always configure cascade delete behavior explicitly
- Add concurrency tokens (`[Timestamp]` or `IsRowVersion()`) for entities that may be edited concurrently
