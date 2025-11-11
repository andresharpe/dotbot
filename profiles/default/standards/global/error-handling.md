## Error Handling Standards

- **Fail Fast**: Detect errors early and fail immediately rather than continuing with invalid state
- **Meaningful Error Messages**: Provide clear, actionable error messages that help users understand what went wrong
- **Proper Exception Types**: Use appropriate exception/error types for different error conditions
- **Graceful Degradation**: When possible, gracefully degrade functionality rather than completely failing
- **Error Logging**: Log errors with sufficient context for debugging (stack traces, input values, system state)
- **User-Friendly Errors**: Translate technical errors into user-friendly messages when appropriate
- **Don't Swallow Errors**: Avoid catching errors without handling them; let them bubble up if you can't handle them
- **Validation**: Validate inputs early and provide clear feedback about what's wrong
- **Recovery Mechanisms**: Implement retry logic, fallbacks, or recovery mechanisms where appropriate

