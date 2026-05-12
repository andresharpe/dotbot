---
name: implement-api-endpoint
description: "Implement ASP.NET Core REST API endpoints with routing, validation, MediatR handlers, and proper HTTP status codes. Use when creating new API routes, adding HTTP endpoints, building RESTful resources, implementing controllers, or adding GET/POST/PUT/DELETE operations."
auto_invoke: true
---

# Implement API Endpoint

Implement REST API endpoints in ASP.NET Core with thin controllers and service-layer delegation.

## Workflow

1. **Define the route** — resource-oriented URL following REST conventions
2. **Create request/response DTOs** — never expose domain entities
3. **Implement handler** — business logic in service layer or MediatR handler
4. **Wire the controller action** — validate, delegate, return appropriate status code
5. **Verify** — test happy path, validation errors, and error responses

## Controller Pattern

```csharp
[ApiController]
[Route("api/[controller]")]
public class ItemsController : ControllerBase
{
    private readonly IMediator _mediator;
    public ItemsController(IMediator mediator) => _mediator = mediator;

    [HttpGet("{id:guid}")]
    public async Task<IActionResult> GetItem(Guid id)
    {
        var result = await _mediator.Send(new GetItemQuery(id));
        if (result.IsFailure)
            return NotFound();

        return Ok(result.Value);
    }

    [HttpPost]
    public async Task<IActionResult> CreateItem([FromBody] CreateItemRequest request)
    {
        var result = await _mediator.Send(new CreateItemCommand(request));
        if (result.IsFailure)
            return BadRequest(result.Error);

        return CreatedAtAction(nameof(GetItem), new { id = result.Value.Id }, result.Value);
    }

    [HttpDelete("{id:guid}")]
    public async Task<IActionResult> DeleteItem(Guid id)
    {
        var result = await _mediator.Send(new DeleteItemCommand(id));
        return result.IsFailure ? NotFound() : NoContent();
    }
}
```

## Best Practices

- **Thin controllers** — delegate all business logic to services or MediatR handlers
- **`[ApiController]`** — enables automatic model validation and `[FromBody]` inference
- **DTOs for input/output** — never return domain entities; map with AutoMapper or manual projection
- **Async everywhere** — all I/O-bound actions must use `async Task<IActionResult>`
- **Problem Details** for errors — use `RFC 7807` format via `ProblemDetails` middleware
- **Location header** on `201 Created` — always return `CreatedAtAction` or `CreatedAtRoute`

## Checklist

- [ ] Route follows REST conventions (`GET /resource`, `POST /resource`, etc.)
- [ ] Request and response DTOs defined (no domain entity exposure)
- [ ] Controller action delegates to service/handler — no inline business logic
- [ ] Appropriate HTTP status codes returned (200, 201, 204, 400, 404)
- [ ] Model validation handled (via `[ApiController]` or manual checks)
- [ ] Integration test covers happy path and error cases
