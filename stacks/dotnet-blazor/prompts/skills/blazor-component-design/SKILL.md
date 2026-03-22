---
name: Blazor Component Design
description: Guidance for designing Blazor components following best practices
version: 1.0
---

# Blazor Component Design

## When to Use
- Creating new Blazor components (Server or WASM)
- Refactoring existing component hierarchies
- Implementing component parameters, cascading values, and event callbacks

## Guidelines
- Prefer component parameters over cascading values for explicit data flow
- Use `EventCallback<T>` for parent-child communication
- Keep render logic minimal — extract complex logic into code-behind or services
- Use `@key` directive for list rendering performance
- Implement `IDisposable` when subscribing to events or services
