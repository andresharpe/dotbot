## API Development with ASP.NET Core

### API Design Approaches

- **Controller-Based APIs**: Use controller-based approach for complex APIs requiring attribute routing, model binding, filters, and conventional REST endpoint organization patterns
- **Minimal APIs**: Consider minimal API approach for simple endpoints or microservices where lightweight request delegates are sufficient without full controller infrastructure overhead
- **Hybrid Approach**: Combine controllers for complex APIs with minimal APIs for simple endpoints based on scenario-specific requirements

### Routing & HTTP Methods

- **Route Attributes**: Define routes using attribute routing on controllers and actions with explicit HTTP method attributes like `HttpGet`, `HttpPost`, `HttpPut`, `HttpDelete`
- **RESTful URLs**: Use plural resource names in URLs like `/api/users`, `/api/orders` following REST conventions for consistency and discoverability
- **Versioning**: Implement API versioning using Asp.Versioning libraries to manage multiple API versions simultaneously, supporting backward compatibility during endpoint evolution
- **Semantic Versioning**: Follow semantic versioning practices for API versions (v1, v2, v3) signaling breaking changes, new features, and compatibility levels

### Model Binding & Validation

- **Model Binding**: Rely on automatic model binding for request parameters from route, query string, headers, and body using `FromBody`, `FromRoute`, `FromQuery` attributes explicitly
- **Data Annotations**: Use data annotations on DTOs for simple validation constraints but delegate complex validation to FluentValidation pipeline behaviors
- **Validation Pipeline**: Integrate FluentValidation with MediatR pipeline to validate commands and queries before handler execution centralizing validation logic

### Action Results & Response Types

- **Typed Results**: Return appropriate `ActionResult` types like `Ok`, `CreatedAtAction`, `BadRequest`, `NotFound` with typed results for strongly-typed responses and proper HTTP status codes
- **Problem Details**: Use RFC 7807 Problem Details format for error responses providing structured error information including error code, title, detail, and validation errors
- **Consistent Responses**: Define standard response envelopes for consistency across API endpoints with uniform structure for success and error responses
- **Status Codes**: Use semantically appropriate HTTP status codes (200 OK, 201 Created, 400 Bad Request, 404 Not Found, 500 Internal Server) accurately reflecting response intent

### Error Handling

- **Global Exception Handling**: Use global exception handling middleware to catch unhandled exceptions, log errors with Serilog, and return consistent error responses with problem details
- **Custom Exceptions**: Define custom domain exceptions inheriting from base exception class allowing typed exception handling in middleware with appropriate mappings to HTTP status codes
- **Exception Logging**: Log exceptions with full stack traces, inner exceptions, and contextual properties using Serilog for troubleshooting production issues

### API Example

```csharp
// Application/Commands/CreateUser/CreateUserCommand.cs
public record CreateUserCommand(string Email, string FullName) : IRequest<Guid>;

// Application/Commands/CreateUser/CreateUserCommandHandler.cs
public class CreateUserCommandHandler : IRequestHandler<CreateUserCommand, Guid>
{
    private readonly IUserRepository _repository;
    
    public CreateUserCommandHandler(IUserRepository repository)
    {
        _repository = repository;
    }
    
    public async Task<Guid> Handle(CreateUserCommand request, CancellationToken cancellationToken)
    {
        var user = new User { Email = request.Email, FullName = request.FullName };
        await _repository.AddAsync(user, cancellationToken);
        return user.Id;
    }
}

// Api/Controllers/UsersController.cs
[ApiController]
[Route("api/[controller]")]
public class UsersController : ControllerBase
{
    private readonly IMediator _mediator;
    
    public UsersController(IMediator mediator)
    {
        _mediator = mediator;
    }
    
    [HttpPost]
    [ProducesResponseType(StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> CreateUser(
        [FromBody] CreateUserRequest request,
        CancellationToken cancellationToken)
    {
        var userId = await _mediator.Send(
            new CreateUserCommand(request.Email, request.FullName),
            cancellationToken);
        
        return CreatedAtAction(nameof(GetUser), new { id = userId }, userId);
    }
    
    [HttpGet("{id}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetUser(
        [FromRoute] Guid id,
        CancellationToken cancellationToken)
    {
        var query = new GetUserByIdQuery(id);
        var user = await _mediator.Send(query, cancellationToken);
        
        if (user == null)
            return NotFound();
        
        return Ok(user);
    }
}

// Api/Requests/CreateUserRequest.cs
public record CreateUserRequest(string Email, string FullName);
```

### Performance Optimization

- **Response Compression**: Enable response compression middleware for reducing payload size on text-based responses like JSON APIs improving performance over network connections
- **Caching**: Implement appropriate caching strategies using response caching middleware or distributed caching for frequently accessed data
- **Async Operations**: Always implement endpoints as async operations returning `Task` or `Task<IActionResult>` for better scalability and non-blocking I/O

### API Documentation

- **OpenAPI/Swagger**: Enable Swagger generation with XML documentation providing interactive API documentation for developers
- **Endpoint Descriptions**: Add `[ProducesResponseType]` attributes documenting possible response types and status codes for each endpoint
- **Request/Response Examples**: Include example requests and responses in Swagger documentation improving API usability for consumers
