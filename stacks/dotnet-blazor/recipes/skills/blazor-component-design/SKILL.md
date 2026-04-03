---
name: blazor-component-design
description: "Design Blazor components with proper parameter binding, event callbacks, lifecycle management, and render optimization. Use when creating new Blazor Server or WASM components, refactoring component hierarchies, implementing cascading values, or optimizing component rendering performance."
---

# Blazor Component Design

Design and implement Blazor components following project conventions.

## Workflow

1. **Define component parameters** — identify inputs, event callbacks, and cascading values
2. **Implement render logic** — keep `.razor` lean, extract complex logic to code-behind
3. **Wire parent-child communication** — use `EventCallback<T>` for upward data flow
4. **Handle lifecycle** — implement `OnInitializedAsync`, `OnParametersSetAsync` as needed
5. **Optimize rendering** — add `@key` for lists, `ShouldRender()` for expensive components

## Component Structure

```razor
@* ItemCard.razor *@
<div class="item-card" @key="Item.Id">
    <h3>@Item.Name</h3>
    <p>@Item.Description</p>
    <button @onclick="HandleSelect">Select</button>
</div>

@code {
    [Parameter, EditorRequired]
    public ItemDto Item { get; set; } = default!;

    [Parameter]
    public EventCallback<ItemDto> OnSelected { get; set; }

    private async Task HandleSelect() => await OnSelected.InvokeAsync(Item);
}
```

## Code-Behind Pattern

```csharp
// ItemList.razor.cs
public partial class ItemList : ComponentBase, IDisposable
{
    [Inject] private IItemService ItemService { get; set; } = default!;
    [Parameter] public string? FilterCategory { get; set; }

    private List<ItemDto> _items = new();

    protected override async Task OnParametersSetAsync()
    {
        _items = await ItemService.GetItemsAsync(FilterCategory);
    }

    public void Dispose() { /* unsubscribe from events */ }
}
```

## Best Practices

- **Parameters over cascading values** — explicit data flow is easier to trace and debug
- **`EventCallback<T>`** for parent-child communication — never mutate parent state directly
- **Code-behind** for components with logic — keeps `.razor` focused on markup
- **`@key` directive** on list items — prevents DOM thrashing on re-renders
- **`IDisposable`** when subscribing to events, timers, or injected services with subscriptions
- **`[EditorRequired]`** on mandatory parameters — catches missing bindings at compile time

## Checklist

- [ ] Component parameters use `[Parameter]` with `[EditorRequired]` where appropriate
- [ ] Parent-child communication uses `EventCallback<T>`, not direct state mutation
- [ ] Complex logic extracted to code-behind (`.razor.cs`) or services
- [ ] `@key` added to list-rendered items
- [ ] `IDisposable` implemented when subscribing to events or services
- [ ] Render logic is minimal — no heavy computation in `.razor` markup
