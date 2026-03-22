---
name: implement-api-endpoint
description: Implement REST API endpoints with proper routing, validation, error handling, and response formatting
auto_invoke: true
---

# Implement API Endpoint

Guide for implementing REST API endpoints following best practices.

## When to Use

- Creating new API routes
- Adding HTTP endpoints (GET, POST, PUT, DELETE, PATCH)
- Building RESTful resources
- Implementing controllers or handlers

## Endpoint Structure

### 1. Route Definition
- Use clear, resource-oriented URLs
- Follow REST conventions:
  - `GET /resource` - List
  - `GET /resource/{id}` - Get single
  - `POST /resource` - Create
  - `PUT /resource/{id}` - Update (full)
  - `PATCH /resource/{id}` - Update (partial)
  - `DELETE /resource/{id}` - Delete

### 2. Request Handling
- **Validate input** - Check required fields, formats, ranges
- **Parse body** - Deserialize JSON/form data
- **Extract parameters** - Route params, query strings, headers
- **Authentication/Authorization** - Check permissions early

### 3. Business Logic
- Delegate to service layer or command/query handlers
- Keep controllers thin - no business logic
- Use dependency injection for services
- Handle domain validation

### 4. Response Formatting
- Use appropriate status codes:
  - `200 OK` - Successful GET/PUT/PATCH
  - `201 Created` - Successful POST
  - `204 No Content` - Successful DELETE
  - `400 Bad Request` - Validation errors
  - `401 Unauthorized` - Authentication required
  - `403 Forbidden` - Insufficient permissions
  - `404 Not Found` - Resource doesn't exist
  - `500 Internal Server Error` - Unexpected errors

- Return consistent response formats
- Include relevant data in response body
- Add location header for 201 responses

### 5. Error Handling
- Catch exceptions appropriately
- Return problem details or error objects
- Log errors for debugging
- Don't expose internal details in responses

## Example Pattern

```csharp
[HttpPost("/api/items")]
public async Task<IActionResult> CreateItem([FromBody] CreateItemRequest request)
{
    // 1. Validate
    if (!ModelState.IsValid)
        return BadRequest(ModelState);
    
    // 2. Execute business logic (via service/handler)
    var result = await _mediator.Send(new CreateItemCommand(request));
    
    // 3. Handle result
    if (result.IsFailure)
        return BadRequest(result.Error);
    
    // 4. Return response
    return CreatedAtAction(
        nameof(GetItem),
        new { id = result.Value.Id },
        result.Value);
}
```

## Best Practices

- **Async/await** - Use async methods for I/O operations
- **DTOs** - Use Data Transfer Objects, don't expose domain entities
- **Versioning** - Consider API versioning strategy
- **Documentation** - Add XML comments or OpenAPI attributes
- **Testing** - Write integration tests for endpoints

## Common Pitfalls

- ❌ Business logic in controllers
- ❌ Returning domain entities directly
- ❌ Inconsistent error responses
- ❌ Missing validation
- ❌ Wrong status codes
- ❌ Synchronous I/O in async endpoints

## Testing Checklist

- [ ] Happy path works
- [ ] Validation errors return 400
- [ ] Missing resources return 404
- [ ] Unauthorized access returns 401/403
- [ ] Response format is correct
- [ ] Status codes are appropriate
- [ ] Errors are logged but not exposed
