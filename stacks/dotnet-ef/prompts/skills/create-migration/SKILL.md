---
name: Create EF Migration
description: Entity Framework Core migration creation and management
version: 1.0
---

# Create EF Migration

## When to Use
- Adding or modifying entity models that require database schema changes
- Setting up a new DbContext for the first time
- Applying data seeding via migrations

## Guidelines
- Always name migrations descriptively (e.g., `AddInvoiceLineItems`, not `Update1`)
- Review the generated migration before applying — check for unintended column drops
- Use `HasData()` for reference/seed data, not migrations with raw SQL
- Keep migrations small and focused on a single schema change
- Test migrations against a local database before committing
