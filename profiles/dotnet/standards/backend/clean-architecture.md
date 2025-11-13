## Clean Architecture Principles

### Layer Organization

- **Layer Separation**: Organize solution into Contracts, Domain, Application, Infrastructure, Shared, and presentation layers with strict dependency rules enforcing inward-only dependencies
- **Dependency Direction**: Ensure outer layers depend on inner layers, never the reverse, with Domain at the center having no dependencies on infrastructure or external concerns
- **Layer Independence**: Each layer should be independently testable and replaceable without affecting other layers

### Domain Layer (Core Business Logic)

- **Domain Layer Purity**: Keep Domain layer pure with no external dependencies except Contracts, containing only entities, value objects, domain events, and business logic
- **Entity Design**: Define entities as objects with unique identity encapsulating business rules and invariants that must always be true
- **Value Objects**: Use value objects for immutable domain concepts without identity like Money, Address, or Email ensuring domain language clarity
- **Domain Events**: Emit domain events from entities to communicate important business occurrences that other parts of the system need to react to
- **No Infrastructure**: Strictly prohibit database access, file I/O, or external API calls in Domain layer to maintain business logic independence from technical implementation

### Application Layer (Use Cases & Services)

- **Application Layer Purpose**: Place all use cases, commands, queries, validators, and application services in Application layer depending only on Domain and Infrastructure abstractions
- **Command Handlers**: Create command handlers for write operations that modify system state, implementing state changes based on domain logic and events
- **Query Handlers**: Create query handlers for read operations that return data without side effects, optimized for query performance without business logic complexity
- **Application Services**: Orchestrate Domain objects and Infrastructure concerns to implement complete use cases handling transactions, notifications, and cross-cutting concerns
- **DTOs in Application**: Define Data Transfer Objects in Application layer for request/response models separating API contracts from internal domain representations

### Infrastructure Layer (External Concerns)

- **Infrastructure Scope**: Implement all external concerns like database access, file system, external APIs, and third-party integrations in Infrastructure layer with interface-based abstractions
- **Repository Implementation**: Implement generic repository pattern wrapping DbContext and providing abstraction for data access making code testable and swappable
- **Service Implementations**: Implement integration services for external APIs, email sending, message queues, and other infrastructure concerns behind Domain interfaces
- **Configuration**: Handle configuration, secrets management, and environment-specific setup in Infrastructure layer during dependency injection registration
- **No Business Logic**: Keep Infrastructure layer free of business rules and logic; it should only handle technical implementation details of abstractions

### Contracts Layer (Public API)

- **Contracts Definition**: Define all DTOs, request/response models, and public contracts in isolated Contracts layer with zero dependencies for maximum reusability
- **API Contracts**: Define request/response DTOs that represent external API contracts independently from internal domain models
- **Cross-Cutting Contracts**: Include validation rules, error responses, and pagination models that multiple layers reference
- **Stability**: Treat Contracts as stable API definitions; changes should follow semantic versioning practices to avoid breaking consumers

### Shared Layer (Utilities & Cross-Cutting Concerns)

- **Shared Purpose**: Use Shared layer for cross-cutting concerns and utilities that are referenced by multiple layers but don't belong to any specific layer
- **Utilities**: Include helper functions, extension methods, and common algorithms used across multiple layers
- **Logging & Caching**: Place cross-cutting infrastructure like logging helpers, caching utilities, or common middleware in Shared layer
- **No Layer Logic**: Avoid placing business logic or layer-specific code in Shared; keep it generic and reusable

### Project Reference Rules

- **Valid References**:
  - Presentation layers reference Application and Infrastructure (but not Domain directly for business logic isolation)
  - Application references Domain and Infrastructure abstractions
  - Infrastructure references Domain for entity implementations
  - Shared references none; it's referenced by all layers
  - Domain references nothing
- **Forbidden References**: No cross-reference between presentation layers, no Infrastructure in Domain, no Domain in external utilities
- **Dependency Injection**: Use DI container to wire dependencies following reference rules at runtime

### Practical Project Structure

```
Solution.sln
├── Solution.Contracts/           # DTOs, API models, exceptions
├── Solution.Domain/              # Business logic, entities, value objects
├── Solution.Application/         # Use cases, commands, queries, services
├── Solution.Infrastructure/      # EF Core, repositories, external integrations
├── Solution.Shared/              # Utilities, extensions, constants
├── Solution.Api/                 # ASP.NET Core controllers, endpoints
├── Solution.BlazorWeb/           # Blazor WebAssembly components
├── Solution.Desktop/             # Avalonia desktop application (if needed)
└── Solution.Tests/               # Unit, integration, and E2E tests
```
