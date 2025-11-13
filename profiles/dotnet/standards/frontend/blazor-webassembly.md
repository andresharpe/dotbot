## Frontend with Blazor WebAssembly

### WebAssembly Hosting & Setup

- **WebAssembly Hosting**: Build client-side SPAs using Blazor WebAssembly hosting model running .NET runtime in browser via WebAssembly for full C# development without JavaScript
- **Lazy Loading**: Configure lazy loading for Blazor components and assemblies reducing initial bundle size and improving startup performance
- **Static Prerendering**: Pre-render root components at build time generating static HTML reducing time-to-first-paint for faster perceived performance
- **Bundle Optimization**: Minimize IL bundle size by trimming unused code and disabling features not needed in WebAssembly deployment

### Component Architecture

- **Component Structure**: Structure UI as reusable Blazor components using `.razor` files with HTML markup, C# code, and component lifecycle methods following component-based architecture
- **Component Composition**: Build complex UIs by combining smaller, simpler components rather than monolithic structures enabling reusability and testability
- **Razor Component Syntax**: Use Razor syntax with `@` directive for data binding, event handling, and control flow reducing verbosity of markup
- **Code-Behind**: Use code-behind pattern in separate `.cs` partial files for complex component logic keeping markup clean and readable
- **Lifecycle Methods**: Use component lifecycle methods (`OnInitializedAsync`, `OnParametersSetAsync`, `OnAfterRender`) appropriately for initialization and state management

### MudBlazor Component Library

- **MudBlazor Usage**: Use MudBlazor component library exclusively for all UI controls including forms, tables, dialogs, navigation, inputs, and layouts ensuring consistent Material Design
- **Component Consistency**: Leverage MudBlazor components for visual consistency eliminating need for custom styling and ensuring professional appearance
- **Theme Configuration**: Configure MudBlazor theme in `Program.cs` specifying color scheme, typography, and spacing for consistent branding
- **Responsive Design**: MudBlazor components are responsive by default adapting to different screen sizes and devices without additional configuration

### Authentication State Management

- **AuthenticationStateProvider**: Use `AuthenticationStateProvider` for managing authentication state and obtaining current user claims throughout application
- **AuthorizeView Component**: Use `AuthorizeView` component for conditional rendering based on user authentication and authorization status
- **Cascading Parameters**: Use cascading parameters to pass authentication state down component hierarchy reducing prop drilling
- **Login/Logout**: Implement login and logout flows integrating with backend authentication endpoints storing tokens securely

### HTTP Client & API Communication

- **HttpClient Factory**: Configure typed `HttpClient` instances using factory pattern for API communication with base addresses, default headers, and authentication token injection
- **Transient HttpClient**: Use transient `HttpClient` registrations for each typed client avoiding socket exhaustion issues with connection pooling
- **Request Interceptors**: Implement custom `HttpMessageHandler` for automatic token injection, request logging, and error handling across all API calls
- **Error Handling**: Handle HTTP errors gracefully providing user-friendly error messages for network failures and API errors

### OData Client Consumption

- **Simple.OData.Client**: Use `Simple.OData.V4.Client` for consuming backend OData endpoints with LINQ-based queries generating OData URLs automatically
- **LINQ Queries**: Write LINQ queries against backend OData endpoints with automatic conversion to OData URL parameters for complex filtering and sorting
- **Result Transformation**: Transform OData results into view models suitable for UI rendering separating API contracts from UI models
- **Pagination**: Implement pagination for OData queries handling large result sets efficiently limiting data transferred per request

### State Management

- **Scoped Services**: Manage application state using scoped services registered with DI container for sharing state across components within same user session
- **State Service Pattern**: Create state service classes holding application state with methods for state modifications and events for notifying consumers of changes
- **Cascading Parameters**: Use cascading parameters to pass parent component state to descendants reducing prop drilling and improving component independence
- **Lazy Loading**: Load state only when needed implementing lazy-loading patterns for expensive operations like initial data fetch

### Form Validation Integration

- **EditForm Component**: Integrate FluentValidation with MudBlazor forms using `EditForm` component and custom validators for client-side validation
- **Validation Mirroring**: Mirror server-side validation rules on client for consistent validation experience improving user feedback
- **Error Display**: Display validation errors prominently near form fields using MudBlazor form components with built-in error support
- **Real-Time Validation**: Implement real-time validation feedback as user types providing immediate validation results without waiting for form submission

### Practical Blazor Component Example

```razor
@* Pages/Users/UserList.razor *@
@page "/users"
@using MyApp.Contracts.Users
@inject IMediator Mediator
@inject NavigationManager Navigation

<MudContainer>
    <MudStack>
        <MudText Typo="Typo.H3">Users</MudText>
        <MudButton Variant="Variant.Filled" Color="Color.Primary" OnClick="@(() => Navigation.NavigateTo("/users/new"))">
            Add User
        </MudButton>
        
        @if (_users == null)
        {
            <MudProgressCircular IsIndeterminate="true" />
        }
        else
        {
            <MudTable Items="@_users" Hover="true" OnRowClick="@(context => OnSelectUser(context.Item))">
                <HeaderContent>
                    <MudTh>Email</MudTh>
                    <MudTh>Name</MudTh>
                    <MudTh>Actions</MudTh>
                </HeaderContent>
                <RowTemplate>
                    <MudTd DataLabel="Email">@context.Email</MudTd>
                    <MudTd DataLabel="Name">@context.FullName</MudTd>
                    <MudTd>
                        <MudButton Variant="Variant.Text" Color="Color.Primary" Size="Size.Small" OnClick="@(() => OnEditUser(context.Id))">Edit</MudButton>
                        <MudButton Variant="Variant.Text" Color="Color.Error" Size="Size.Small" OnClick="@(() => OnDeleteUser(context.Id))">Delete</MudButton>
                    </MudTd>
                </RowTemplate>
            </MudTable>
        }
    </MudStack>
</MudContainer>

@code {
    private List<UserDto>? _users;
    
    protected override async Task OnInitializedAsync()
    {
        await LoadUsersAsync();
    }
    
    private async Task LoadUsersAsync()
    {
        var query = new GetUsersQuery();
        _users = (await Mediator.Send(query)).ToList();
    }
    
    private void OnSelectUser(UserDto user)
    {
        Navigation.NavigateTo($"/users/{user.Id}");
    }
    
    private void OnEditUser(Guid userId)
    {
        Navigation.NavigateTo($"/users/{userId}/edit");
    }
    
    private async Task OnDeleteUser(Guid userId)
    {
        var confirmed = await _dialogService.ShowMessageBox(
            "Delete User",
            "Are you sure you want to delete this user?",
            yesText: "Delete",
            cancelText: "Cancel");
        
        if (confirmed == true)
        {
            await Mediator.Send(new DeleteUserCommand(userId));
            await LoadUsersAsync();
        }
    }
}
```
