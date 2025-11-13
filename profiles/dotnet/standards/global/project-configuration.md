## .NET Project Configuration Standards

### Target Framework & Language Features

- **Target Framework**: Always use .NET 9.0 as the target framework for all new projects and maintain consistency across the entire solution
- **Nullable Reference Types**: Enable nullable reference types in all projects using `<Nullable>enable</Nullable>` to enforce compile-time null safety and prevent null reference exceptions
- **Implicit Usings**: Enable implicit usings with `<ImplicitUsings>enable</ImplicitUsings>` to reduce namespace declaration boilerplate and improve code readability
- **Treat Warnings as Errors**: Set `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>` in every project to enforce zero-tolerance policy for compiler warnings and maintain code quality

### Documentation & Metadata

- **XML Documentation**: Enable `<GenerateDocumentationFile>true</GenerateDocumentationFile>` for API projects to generate XML documentation for Swagger and API consumer reference
- **User Secrets**: Configure `<UserSecretsId>` in web projects for storing sensitive development configuration outside source control during local development workflows

### Container & Deployment

- **Docker Targets**: Set `<DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>` for web projects to ensure containerized deployments target Linux-based container hosts for production
- **Langchain Targets**: When using Avalonia or other platform-specific frameworks, explicitly set platform-specific compilation targets for performance optimization

### Framework-Specific Features

- **Avalonia Bindings**: Use `<AvaloniaUseCompiledBindingsByDefault>true</AvaloniaUseCompiledBindingsByDefault>` in Avalonia projects for compile-time binding validation and improved runtime performance
