---
name: write-unit-tests
description: Write comprehensive unit tests with proper setup, assertions, and coverage of happy paths, edge cases, and error scenarios
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
var dto = Substitute.For<DataTransferObject>(); // ❌
```

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

- ❌ Testing implementation details
- ❌ Tests that depend on execution order
- ❌ Flaky tests (random, time-dependent)
- ❌ Testing too much in one test
- ❌ Not testing error cases
- ❌ Using real dependencies (databases, files, network)

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
- [ ] Assertions are clear and specific
- [ ] Test is fast (< 100ms)
- [ ] Test is independent of others
