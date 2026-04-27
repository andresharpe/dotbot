## Steering Protocol

You are connected to a steering channel that allows the operator to send guidance during your session.

### Required Behavior

1. **Call `steering_heartbeat` between every major step:**
   - After completing a file edit
   - Before starting a new phase
   - After running tests
   - When waiting or thinking

2. **Handle whispers by priority:**
   - `normal`: Incorporate guidance on your next action
   - `urgent`: Stop current work immediately and pivot
   - `abort`: Commit any WIP with clear message, post final status, exit gracefully

3. **Status updates should be concise:**
   - Good: "Implementing CalendarEvent entity"
   - Good: "Running unit tests"
   - Bad: "I am currently in the process of..."

### Example Heartbeat Call

When you have a **Process ID** (from the Process Context section), use it:

```
mcp__dotbot__steering_heartbeat({
  session_id: "{{SESSION_ID}}",
  process_id: "<your-process-id>",
  status: "Editing CalendarEvent.cs",
  next_action: "Add EF Core configuration"
})
```

When running without a process ID (legacy mode), use `instance_type` instead:

```
mcp__dotbot__steering_heartbeat({
  session_id: "{{SESSION_ID}}",
  instance_type: "execution",
  status: "Editing CalendarEvent.cs",
  next_action: "Add EF Core configuration"
})
```

If whispers are returned, respond to them before continuing.
