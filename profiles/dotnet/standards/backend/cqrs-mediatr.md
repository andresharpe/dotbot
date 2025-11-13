## CQRS and MediatR Patterns

### Command Query Responsibility Segregation (CQRS)

- **CQRS Pattern**: Use MediatR library to implement Command Query Responsibility Segregation pattern, separating read and write operations into distinct request handlers
- **Command-Query Separation**: Strictly separate commands (write operations that modify state) from queries (read operations that return data without side effects)
- **Independent Scaling**: Design commands and queries independently allowing different optimization strategies for reads versus writes in the same use case
- **Event Sourcing Integration**: Consider event sourcing for commands to maintain complete audit trail of state changes and enable temporal queries of historical states

### Command Handlers

- **Command Purpose**: Create command handlers in Application layer for write operations that modify system state, implementing `IRequestHandler` interface for each command
- **Single Responsibility**: Each command handler should handle one specific, atomic operation that can succeed or fail as a complete unit of work
- **Command Naming**: Name commands as imperative verbs followed by noun like `CreateUserCommand`, `UpdateOrderCommand`, `DeleteProductCommand` for clarity
- **Idempotency**: Design commands to be idempotent where possible allowing safe retry on transient failures without causing duplicate side effects
- **Return Values**: Commands may return minimal results (like ID of created resource) or void if only side effects matter; keep return values small
- **Async Implementation**: Always implement command handlers as async operations returning `Task` or `Task<TResponse>` for better scalability

### Query Handlers

- **Query Purpose**: Create query handlers in Application layer for read operations that return data without side effects, using `IRequestHandler<TRequest, TResponse>` interface
- **Query Naming**: Name queries as nouns or descriptive phrases like `GetUserByIdQuery`, `SearchProductsQuery`, `ListOrdersQuery` for clarity
- **No Side Effects**: Ensure queries never modify state, emit events, or trigger side effects allowing queries to be executed any number of times safely
- **Optimization**: Optimize queries for performance using views, projections, or specialized read models rather than forcing queries through domain layer
- **Pagination**: Implement pagination for queries returning large datasets using standard pagination parameters (PageNumber, PageSize) reducing memory usage
- **Eager Loading**: Use eager loading with Include/ThenInclude to optimize queries fetching related data in single round-trip to avoid N+1 query problems

### Request & Response Models

- **Request Models**: Define all MediatR requests as records or immutable classes in Application layer, ensuring immutability for requests where possible
- **Command Requests**: Create separate command request classes for each command with properties representing command parameters as strongly-typed alternatives to parameter objects
- **Query Requests**: Define query request classes containing filter, sort, and pagination parameters with defaults for optional parameters
- **Response Models**: Define response DTOs matching API contract requirements transforming domain objects to DTOs for API response serialization
- **Null Safety**: Use nullable reference types ensuring all properties are either non-nullable with initialization or explicitly nullable with `?` annotation

### Handler Registration & Discovery

- **Automatic Registration**: Register all MediatR handlers automatically using `AddMediatR` extension method during dependency injection configuration pointing to assembly containing handlers
- **Assembly Scanning**: Leverage MediatR's assembly scanning to discover and register all `IRequestHandler` implementations automatically without manual registration
- **Alternative Registration**: For advanced scenarios use factory delegates or custom registrations to register specific implementations when automatic discovery insufficient
- **Pipeline Configuration**: Configure MediatR pipeline behaviors at registration time for cross-cutting concerns like validation, logging, and transaction management

### Pipeline Behaviors

- **Behavior Purpose**: Implement cross-cutting concerns like validation, logging, and transactions as MediatR pipeline behaviors that wrap handler execution automatically
- **Validation Behavior**: Create validation behavior executing FluentValidation validators before handler execution throwing `ValidationException` on rule failures
- **Logging Behavior**: Implement logging behavior recording command/query execution, timing, and results for observability and debugging
- **Transaction Behavior**: Create transaction behavior for commands wrapping execution in database transaction ensuring atomicity for multi-step operations
- **Behavior Ordering**: Configure behavior ordering ensuring validation runs before logging and transactions wrapping both for proper error handling and transaction semantics
- **Exception Handling**: Handle exceptions in behaviors transforming technical exceptions to domain-appropriate responses before bubbling up

### Command & Query Organization

```
Application/
├── Commands/
│   ├── CreateUser/
│   │   ├── CreateUserCommand.cs
│   │   └── CreateUserCommandHandler.cs
│   ├── UpdateOrder/
│   │   ├── UpdateOrderCommand.cs
│   │   └── UpdateOrderCommandHandler.cs
│   └── DeleteProduct/
│       ├── DeleteProductCommand.cs
│       └── DeleteProductCommandHandler.cs
├── Queries/
│   ├── GetUserById/
│   │   ├── GetUserByIdQuery.cs
│   │   └── GetUserByIdQueryHandler.cs
│   ├── SearchProducts/
│   │   ├── SearchProductsQuery.cs
│   │   └── SearchProductsQueryHandler.cs
│   └── ListOrders/
│       ├── ListOrdersQuery.cs
│       └── ListOrdersQueryHandler.cs
└── Behaviors/
    ├── ValidationBehavior.cs
    ├── LoggingBehavior.cs
    └── TransactionBehavior.cs
```
