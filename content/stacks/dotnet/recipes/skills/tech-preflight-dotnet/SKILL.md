---
name: tech-preflight-dotnet
description: "Verify .NET SDK compatibility, map project dependency graphs, and run baseline builds before code changes. Use when starting a new task, onboarding to a .NET solution, checking environment readiness, or diagnosing build failures from SDK mismatches."
auto_invoke: false
---

# .NET Environment Pre-flight

Validate the local .NET environment against the solution's requirements before any code changes begin.

## Workflow

1. **Check SDK/runtime compatibility** — run `dotnet --list-sdks`, compare against `<TargetFramework>` and `<TargetFrameworks>` (plural, for multi-targeting) in all `.csproj` files, flag gaps
2. **Map the dependency graph** — run `dotnet list {solution}.sln reference`, identify layering violations
3. **Run baseline build** — run `dotnet build {solution}.sln`, record error/warning counts for later comparison

## 1. SDK/Runtime Compatibility

```bash
dotnet --list-sdks
# Compare output against <TargetFramework> and <TargetFrameworks> values in *.csproj
```

- Flag any target framework without a matching SDK (e.g., `net7.0` targeted but only `net8.0` installed)
- Note whether rollforward is viable (works for minor version gaps)
- Record in `environment.sdk_gaps`

## 2. Project Dependency Graph

```bash
dotnet list {solution}.sln reference
```

For each project in the output:
- Map which projects reference which
- Identify layering patterns (e.g., `.Interfaces` → `.Core` is OK, `.Interfaces` → `.Entities` may not be)
- Record in `environment.dependency_graph`

**Architecture enforcement** — when placing new types:
- Do NOT add references that violate the existing dependency direction
- If a new type references entities from project B, it must live in a project that already references B
- Include any required `<ProjectReference>` additions in implementation guidance
- Flag circular dependencies immediately

## 3. Baseline Build

```bash
dotnet build {solution}.sln
```

- Record error count, warning count, and specific error messages
- Record in `environment.baseline_build`
- The execution phase compares against this to distinguish new vs pre-existing failures

## Checklist

- [ ] All target frameworks have matching SDKs (or viable rollforward)
- [ ] Dependency graph has no circular references
- [ ] Baseline build output captured for comparison
- [ ] Any SDK gaps or layering issues flagged before code changes begin
