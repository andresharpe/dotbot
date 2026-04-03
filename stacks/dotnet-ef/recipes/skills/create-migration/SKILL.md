---
name: create-migration
description: "Create and manage Entity Framework Core database migrations including schema changes, seed data, and rollback strategies. Use when adding or modifying EF Core entities, setting up a new DbContext, applying data seeding, running dotnet ef commands, or troubleshooting migration conflicts."
---

# Create EF Migration

Create, review, and apply Entity Framework Core migrations safely.

## Workflow

1. **Make entity/model changes** in code
2. **Generate migration** with a descriptive name
3. **Review the generated migration** — verify no unintended column drops or data loss
4. **Apply to local database** and verify
5. **Commit** migration files with the related entity changes

## Creating Migrations

```bash
# Generate a new migration (from the project directory containing the DbContext)
dotnet ef migrations add AddInvoiceLineItems --project src/MyApp.Data --startup-project src/MyApp.Api

# Apply to local database
dotnet ef database update --project src/MyApp.Data --startup-project src/MyApp.Api

# Rollback to a previous migration
dotnet ef database update PreviousMigrationName --project src/MyApp.Data --startup-project src/MyApp.Api

# Remove the last unapplied migration
dotnet ef migrations remove --project src/MyApp.Data --startup-project src/MyApp.Api
```

## Best Practices

- **Descriptive names**: `AddInvoiceLineItems`, `RenameUserEmailToContactEmail` — never `Update1`
- **Small and focused**: One schema change per migration for easier rollback
- **Seed data**: Use `HasData()` in `OnModelCreating` or `IEntityTypeConfiguration<T>`, not raw SQL in migrations
- **Review before applying**: Check the generated `Up()` and `Down()` methods for unintended drops or data loss
- **Test locally**: Always apply against a local database before committing

## Checklist

- [ ] Migration has a descriptive, intention-revealing name
- [ ] Generated `Up()` and `Down()` methods reviewed for correctness
- [ ] No unintended column drops or data loss
- [ ] Migration applied successfully to local database
- [ ] Seed data uses `HasData()`, not raw SQL
- [ ] Migration files committed alongside entity changes
