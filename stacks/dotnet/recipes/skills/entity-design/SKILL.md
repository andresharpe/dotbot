---
name: entity-design
description: Design and document domain entities with consistent structure, relationships, and audit fields following project conventions
auto_invoke: true
---

# Entity Design

Guide for designing and documenting domain entities in a consistent, well-structured format.

## When to Use

- Designing new domain entities
- Documenting existing entity models
- Adding fields to existing entities
- Reviewing entity relationships
- Planning database schema changes

## Entity Model Document Structure

Entity model documents should follow this structure:

### 1. Overview Section
```markdown
## Overview

Brief description of what this entity model covers and its purpose.
```

### 2. EntityBase Section

All entities inherit common audit fields:

```markdown
## EntityBase

All entities in the system inherit these audit fields:

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `CreatedAtUtc` | datetime | UTC timestamp when record was created | 2026-01-09T15:30:00Z |
| `CreatedBy` | string | User/system that created the record | "system" |
| `UpdatedAtUtc` | datetime | UTC timestamp when record was last updated | 2026-01-09T16:45:00Z |
| `UpdatedBy` | string | User/system that last updated the record | "admin" |
| `DeletedAtUtc` | datetime (nullable) | UTC timestamp when record was soft-deleted | 2026-01-10T10:00:00Z |
| `DeletedBy` | string (nullable) | User/system that soft-deleted the record | "admin" |
```

### 3. Individual Entity Sections

Each entity should follow this template:

```markdown
### EntityName

**Purpose:** One-line description of what this entity represents

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `Id` | int | Primary key | 42 |
| `FieldName` | type | Description | example_value |

**Enums:**
- `EnumField`: VALUE_1, VALUE_2, VALUE_3

**Relationships:**
- EntityName 1 → N OtherEntity
- N → 1 ParentEntity

**Notes:**
- Important implementation notes
- Constraints or business rules
```

## Field Naming Conventions

This project uses **PascalCase** for both C# properties and database columns (EF Core default behavior):

- `CreatedAtUtc` - not `created_at_utc`
- `SenderId` - not `sender_id`
- `IsDeleted` - not `is_deleted`

### Primary Keys
- Use auto-increment integers: `Id` | int
- Named simply `Id` (not `EntityNameId`)

### Foreign Keys
- Reference the full field name: `ParentEntityId` | int
- Add "Foreign key to X" in description

### Common Types
- `string` - Text fields
- `string (nullable)` - Optional text
- `int` - Integers
- `decimal` - Numbers with decimals
- `bool` - True/false
- `datetime` - Timestamps (always UTC unless `Local` suffix)
- `jsonb` - JSON data (complex structures, arrays)
- `enum` - Enumerated values (list in Enums section)

### Nullable Fields
- Append `(nullable)` to type: `string (nullable)`
- Only mark nullable if null has semantic meaning

## Relationship Notation

Use arrows to show cardinality:
- `1 → N` - One-to-many
- `N → 1` - Many-to-one
- `1 → 1` - One-to-one
- `N ↔ N` - Many-to-many (note the join entity)

Include context when helpful:
- `Email 1 → N Attachment`
- `N → 1 Sender`
- `MeetingRequest 1 → 1 CalendarEvent (optional)`

## Design Principles

### 1. Soft Deletes
Never hard delete records. Always use:
- `DeletedAtUtc` - When deleted
- `DeletedBy` - Who deleted

### 2. UTC Timestamps
- Primary timestamps always UTC with `Utc` suffix
- Local timestamps optional for display, use `Local` suffix
- Store timezone separately if needed

### 3. Integer Primary Keys
- Auto-increment integers for simplicity
- Good SQLite performance
- Easy to reference in logs and debugging

### 4. Audit Fields
Every entity inherits EntityBase audit fields automatically.

### 5. JSONB for Complex Data
Use JSONB for:
- Variable-length arrays
- Nested structures
- Configuration objects
- Avoid over-normalisation

## Example Entity

```markdown
### Order

**Purpose:** Customer order containing one or more line items

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `Id` | int | Primary key | 1234 |
| `CustomerId` | int | Foreign key to Customer | 42 |
| `OrderNumber` | string | Human-readable order number | "ORD-2026-00123" |
| `Status` | enum | Current order state | "CONFIRMED" |
| `TotalAmount` | decimal | Order total | 150.00 |
| `Currency` | string (ISO 4217) | Currency code | "USD" |
| `PlacedAtUtc` | datetime | When order was placed | 2026-01-15T14:00:00Z |
| `Notes` | string (nullable) | Customer notes | "Leave at door" |
| `Metadata` | jsonb (nullable) | Additional data | `{"source": "web"}` |

**Enums:**
- `Status`: DRAFT, CONFIRMED, PROCESSING, SHIPPED, DELIVERED, CANCELLED

**Relationships:**
- N → 1 Customer
- Order 1 → N OrderLineItem
- Order 1 → N OrderStatusHistory

**Notes:**
- Order number generated on confirmation, not creation
- Total calculated from line items, stored for performance
```

## Key Design Decisions Section

Document major architectural decisions at the end:

```markdown
## Key Design Decisions

### 1. Decision Name
- What was decided
- Why this approach
- Trade-offs considered

### 2. Another Decision
- What was decided
- Why this approach
```

## Checklist

- [ ] Overview section describes the entity model scope
- [ ] EntityBase documented with audit fields
- [ ] Each entity has Purpose, Fields table, Enums, Relationships
- [ ] Field names use PascalCase
- [ ] Primary keys are int named `Id`
- [ ] Foreign keys are int referencing parent `Id`
- [ ] Nullable fields explicitly marked
- [ ] Enums listed with all values
- [ ] Relationships use correct notation
- [ ] Notes capture important constraints
- [ ] Entity Relationship Summary provides overview
- [ ] Key Design Decisions documented
