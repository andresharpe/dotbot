---
name: write-unit-tests
description: Write comprehensive unit tests with proper setup, assertions, and coverage — .NET override with mock completeness guidance
auto_invoke: true
---

# Write Unit Tests

Guide for writing effective unit tests that verify behavior and catch regressions.

## When to Use

- Testing pure logic and business rules
- Verifying individual components in isolation
- Testing edge cases and error conditions
- TDD red-green-refactor cycle

## Test Structure (Arrange-Act-Assert)

```csharp
[Fact]
public void MethodName_Scenario_ExpectedBehavior()
{
    // Arrange - Set up test data and dependencies
    var dependency = Substitute.For<IDependency>();
    dependency.GetData().Returns(expectedData);
    var sut = new SystemUnderTest(dependency);

    // Act - Execute the behavior being tested
    var result = sut.MethodUnderTest(input);

    // Assert - Verify expected outcomes
    result.Should().Be(expectedValue);
    dependency.Received(1).GetData();
}
```

## Test Naming

Use descriptive names that explain what's being tested:
- `MethodName_Scenario_ExpectedBehavior`
- `MethodName_WhenCondition_ShouldDoSomething`
- `MethodName_GivenInput_ReturnsExpectedOutput`

Examples:
- `Calculate_WithNegativeNumber_ThrowsArgumentException`
- `ProcessOrder_WhenInventoryInsufficient_ReturnsFailureResult`
- `FormatDate_GivenNull_ReturnsEmptyString`

## Test Coverage

### 1. Happy Path
- Normal, expected inputs
- Successful execution
- Expected outputs

### 2. Edge Cases
- Boundary values (min, max, zero, empty)
- Null inputs
- Empty collections
- Special characters

### 3. Error Scenarios
- Invalid inputs
- Exceptions
- Validation failures
- Constraint violations

## Mocking & Isolation

- Use test doubles for dependencies
- Mock external services, databases, APIs
- Keep tests fast and deterministic
- Don't mock what you don't own (value objects, DTOs)

```csharp
// Good - Mock interface
var repository = Substitute.For<IRepository>();

// Bad - Don't mock concrete classes or value objects
var dto = Substitute.For<DataTransferObject>(); // don't do this
```

## .NET Test Mock Completeness

When writing or modifying tests (xUnit, NUnit, MSTest with Moq/NSubstitute):

1. **Trace the full call graph** of the method under test. Every injected dependency invoked (directly or transitively) must be mocked — not just the primary ones.
2. **Study existing test fixtures** in the same test class. Identify services that need default mock returns (e.g., `_languageService.GetAllLanguages()` returning an empty list). Replicate these in your test setup.
3. **Verify test configuration matches test intent** — if a test expects validation to fail, ensure the relevant setting is enabled in the fixture (e.g., `isHoneypotEnabled: true` for a honeypot test).
4. **Run tests after writing them** — do not mark the task done until all new tests pass.

## Assertions

Use fluent assertions for clarity:

```csharp
// Good - Fluent and readable
result.Should().Be(expected);
result.Should().BeEquivalentTo(expected);
collection.Should().HaveCount(3);
action.Should().Throw<ArgumentException>()
    .WithMessage("*invalid*");

// Avoid - Less clear
Assert.Equal(expected, result);
Assert.True(result != null);
```

## Best Practices

- **One assertion per test** - Test one thing at a time
- **Fast execution** - No I/O, no sleeps, no real dependencies
- **Deterministic** - Same inputs always produce same results
- **Independent** - Tests don't depend on each other
- **Readable** - Clear setup, action, and verification
- **Maintainable** - Easy to update when requirements change

## Common Patterns

### Testing Exceptions
```csharp
[Fact]
public void Method_InvalidInput_ThrowsException()
{
    var sut = new SystemUnderTest();

    var action = () => sut.Method(invalidInput);

    action.Should().Throw<ArgumentException>()
        .WithMessage("*parameter*");
}
```

### Testing Async Methods
```csharp
[Fact]
public async Task MethodAsync_Scenario_ExpectedBehavior()
{
    var sut = new SystemUnderTest();

    var result = await sut.MethodAsync();

    result.Should().NotBeNull();
}
```

### Theory Tests (Multiple Inputs)
```csharp
[Theory]
[InlineData(0, 0)]
[InlineData(1, 1)]
[InlineData(-1, 1)]
public void Abs_VariousInputs_ReturnsAbsoluteValue(int input, int expected)
{
    var result = Math.Abs(input);
    result.Should().Be(expected);
}
```

## Common Pitfalls

- Testing implementation details
- Tests that depend on execution order
- Flaky tests (random, time-dependent)
- Testing too much in one test
- Not testing error cases
- Using real dependencies (databases, files, network)
- Missing mock setups for transitive dependencies (NullReferenceException at runtime)

## Test Organization

```
Tests/
├── Unit/
│   ├── Services/
│   │   └── OrderServiceTests.cs
│   ├── Handlers/
│   │   └── CreateOrderHandlerTests.cs
│   └── Validators/
│       └── OrderValidatorTests.cs
```

## Checklist

- [ ] Test name clearly describes what's being tested
- [ ] Arrange-Act-Assert structure
- [ ] Happy path covered
- [ ] Edge cases covered
- [ ] Error scenarios covered
- [ ] Dependencies are mocked
- [ ] **All transitive dependencies** have mock setups (traced full call graph)
- [ ] **Existing fixture patterns** replicated in new test setup
- [ ] Assertions are clear and specific
- [ ] Test is fast (< 100ms)
- [ ] Test is independent of others
- [ ] **Tests actually pass** when run
