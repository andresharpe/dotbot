---
name: .NET Environment Pre-flight
description: SDK compatibility, project dependency graph, and baseline build for .NET projects
auto_invoke: false
---

# .NET Environment Pre-flight

## 1. SDK/Runtime Compatibility

Run `dotnet --list-sdks` and compare against `<TargetFramework>` values in all `.csproj` files.

- Flag any target framework without a matching SDK (e.g., "net7.0 targeted, only net8.0 installed")
- Note whether rollforward is viable (usually works for minor version gaps)
- Include in `environment.sdk_gaps`

## 2. Project Dependency Graph

For the solution file, run:
```bash
dotnet list {solution}.sln reference
```

For each project in the output:
- Map which projects reference which
- Identify layering patterns (e.g., `.Interfaces` → `.Core` is OK, `.Interfaces` → `.Entities` may not be)
- Include the graph in `environment.dependency_graph`

**Architecture enforcement:** When the execution phase proposes placing new types:
- Do NOT place types in a project that would require a reference violating the existing dependency direction
- If a new type references entities from project B, it must live in a project that already references B (or where adding that reference is architecturally sound)
- Include any required `<ProjectReference>` additions in the implementation guidance
- Flag any change that would create a circular dependency

## 3. Baseline Build

Run `dotnet build {solution}.sln` and capture output:
- Record error count, warning count, specific error messages
- Include in `environment.baseline_build`
- The execution/remediation phase compares against this to distinguish new vs pre-existing failures
